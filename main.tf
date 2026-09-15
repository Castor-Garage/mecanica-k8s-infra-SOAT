# Provisiona o cluster Kubernetes (EKS) na AWS Academy (Learner Lab) para o
# Tech Challenge Fase 3 - repositorio 2 dos 4 exigidos ("Infraestrutura
# Kubernetes (Terraform)"). Portado de mecanica-pos-SOAT/infra/aws (Fase 2),
# SEM o banco de dados: o Postgres em cluster foi substituido pelo RDS
# gerenciado, provisionado em mecanica-db-infra-SOAT (repositorio 3).
#
#   1. Cluster EKS + node group, reaproveitando o LabRole (Academy nao deixa
#      criar IAM roles novas) como cluster role e node role.
#   2. Tags de ELB nas subnets default, necessarias para o Service
#      "LoadBalancer" da API conseguir provisionar um Network Load Balancer.
#   3. metrics-server (necessario para o HPA em k8s/api/hpa.yaml funcionar,
#      no repositorio da aplicacao principal).
#   4. StorageClass gp3 (EKS nao vem com uma default) e o addon EBS CSI.
#
# Os manifestos da aplicacao (k8s/api/* em mecanica-pos-SOAT) e o banco de
# dados (mecanica-db-infra-SOAT) NAO sao aplicados aqui de proposito: cada
# um e responsabilidade do proprio pipeline de CI/CD do seu repositorio,
# contra o cluster que este modulo ja deixa no ar.
#
# Autenticacao na AWS via variaveis de ambiente padrao (AWS_ACCESS_KEY_ID,
# AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN) — nada de credencial hardcoded
# aqui. Sessoes do Academy sao temporarias: se expirar, so renovar as
# variaveis de ambiente e rodar "terraform apply" de novo.

provider "aws" {
  region = var.aws_region
}

locals {
  kube_context            = var.cluster_name
  metrics_server_manifest = "${path.module}/manifests/metrics-server.yaml"
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  # us-east-1e nao suporta control plane de EKS nesta conta (erro
  # UnsupportedAvailabilityZoneException) — restringe as AZs suportadas.
  filter {
    name   = "availability-zone"
    values = var.eks_supported_azs
  }
}

# Subnets default nao vem marcadas para descoberta automatica do
# LoadBalancer controller do EKS — sem essas tags o Service type=LoadBalancer
# da aplicacao principal fica preso em "pending".
resource "aws_ec2_tag" "cluster_shared" {
  for_each    = toset(data.aws_subnets.default.ids)
  resource_id = each.value
  key         = "kubernetes.io/cluster/${var.cluster_name}"
  value       = "shared"
}

resource "aws_ec2_tag" "elb_role" {
  for_each    = toset(data.aws_subnets.default.ids)
  resource_id = each.value
  key         = "kubernetes.io/role/elb"
  value       = "1"
}

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = var.lab_role_arn

  # atributo imutavel (qualquer mudanca forca recriar o cluster inteiro) -
  # fixado em false para bater com o valor real do cluster ja provisionado,
  # já que o default do provider mudou para true em versoes mais novas.
  bootstrap_self_managed_addons = false

  vpc_config {
    subnet_ids = data.aws_subnets.default.ids
  }
}

# Node groups gerenciados criam as instancias com IMDSv2 hop-limit=1 por
# padrao, o que bloqueia pods de acessarem o Instance Metadata Service (so o
# host consegue). Sem isso, o ebs-csi-controller (e qualquer pod que precise
# das credenciais do LabRole via IMDS) fica em CrashLoopBackOff com "no EC2
# IMDS role found". O launch template abaixo sobe o hop-limit para 2.
resource "aws_launch_template" "node" {
  name_prefix = "${var.cluster_name}-ng-"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.cluster_name}-node"
    }
  }
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-ng"
  node_role_arn   = var.lab_role_arn
  subnet_ids      = data.aws_subnets.default.ids
  instance_types  = [var.instance_type]

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  scaling_config {
    desired_size = var.desired_size
    min_size     = var.min_size
    max_size     = var.max_size
  }
}

resource "null_resource" "kubeconfig" {
  depends_on = [aws_eks_node_group.this]

  # sempre reroda: cada CI run parte de um runner novo, sem ~/.kube/config -
  # um trigger baseado em valor estatico faria o Terraform pular esta etapa
  # (nada mudou desde o ultimo apply) mesmo sem o contexto existir no runner
  # atual, quebrando os null_resource abaixo que dependem dele.
  triggers = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = "aws eks update-kubeconfig --name \"${var.cluster_name}\" --region \"${var.aws_region}\" --alias \"${local.kube_context}\""
  }
}

# EKS puro nao vem com StorageClass padrao nem driver de disco instalado.
# Sem service_account_role_arn: o addon usa a role do proprio node (LabRole)
# para chamar as APIs de EBS, ja que nao da pra criar uma IAM role dedicada
# via IRSA no Academy.
resource "aws_eks_addon" "ebs_csi" {
  depends_on                  = [aws_eks_node_group.this]
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "aws-ebs-csi-driver"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "null_resource" "storage_class" {
  depends_on = [aws_eks_addon.ebs_csi, null_resource.kubeconfig]

  triggers = {
    manifest_hash = filesha256("${path.module}/manifests/storageclass.yaml")
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = "kubectl --context \"${local.kube_context}\" apply -f \"${path.module}/manifests/storageclass.yaml\""
  }
}

resource "null_resource" "metrics_server" {
  depends_on = [null_resource.kubeconfig]

  triggers = {
    manifest_hash = filesha256(local.metrics_server_manifest)
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -e
      kubectl --context "${local.kube_context}" apply -f "${local.metrics_server_manifest}"
      kubectl --context "${local.kube_context}" -n kube-system rollout status deployment/metrics-server --timeout=180s
    EOT
  }
}

# New Relic Kubernetes integration (Helm chart nri-bundle) - monitora pods e
# nodes do cluster inteiro. Segue o mesmo padrao de local-exec+CLI usado acima
# para metrics-server/storageclass (sem provider helm/kubernetes do Terraform),
# pra nao precisar credenciar outro provider so pra isso.
resource "null_resource" "newrelic_kubernetes" {
  depends_on = [null_resource.kubeconfig, aws_eks_node_group.this]

  triggers = {
    values_hash = filesha256("${path.module}/manifests/newrelic-values.yaml")
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -e
      helm repo add newrelic https://helm-charts.newrelic.com >/dev/null 2>&1 || true
      helm repo update newrelic
      helm upgrade --install newrelic-bundle newrelic/nri-bundle \
        --kube-context "${local.kube_context}" \
        --namespace newrelic --create-namespace \
        --set global.licenseKey="${var.new_relic_license_key}" \
        -f "${path.module}/manifests/newrelic-values.yaml"
    EOT
  }
}
