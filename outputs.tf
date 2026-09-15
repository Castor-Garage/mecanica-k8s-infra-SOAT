output "cluster_name" {
  description = "Nome do cluster EKS provisionado"
  value       = aws_eks_cluster.this.name
}

output "kubectl_context" {
  description = "Contexto kubectl a usar para falar com o cluster (kubectl --context <valor>)"
  value       = local.kube_context
}

output "update_kubeconfig_command" {
  description = "Comando para configurar o kubectl localmente apontando para este cluster"
  value       = "aws eks update-kubeconfig --name ${var.cluster_name} --region ${var.aws_region} --alias ${local.kube_context}"
}

output "api_url_hint" {
  description = "Como descobrir a URL publica da API depois que o deploy de mecanica-pos-SOAT publicar k8s/api/ neste cluster"
  value       = "kubectl --context ${local.kube_context} -n castor-garage get svc castor-garage-api -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
}

output "newrelic_check_command" {
  description = "Comando para verificar se os pods da integracao Kubernetes da New Relic (nri-bundle) estao rodando"
  value       = "kubectl --context ${local.kube_context} -n newrelic get pods"
}
