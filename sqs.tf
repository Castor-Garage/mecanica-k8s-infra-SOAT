# Filas Amazon SQS para o Saga Pattern da Fase 4 (ver ADR 0006 em
# mecanica-pos-SOAT/docs): uma fila de comando por servico consumidor
# (billing-commands, execucao-commands) e uma fila de eventos compartilhada
# de volta para o OS Service (os-events, fan-in). Cada fila tem uma DLQ
# propria - uma mensagem que falha repetidamente (bug no consumer, Mercado
# Pago fora do ar, etc.) vai para la em vez de ficar sendo reprocessada para
# sempre, o que da um sinal claro para alertar (saga presa em status
# intermediario).
#
# As credenciais de acesso vem do LabRole (mesma role dos nodes do EKS, via
# IMDS) - nao e criada nenhuma IAM policy nova aqui, pelo mesmo motivo que o
# resto deste repositorio nao cria: a AWS Academy nao permite IAM roles
# novas, e o LabRole ja e amplo o suficiente para SQS.

locals {
  saga_queues = toset([
    "billing-commands",
    "execucao-commands",
    "os-events",
  ])
}

resource "aws_sqs_queue" "saga_dlq" {
  for_each = local.saga_queues

  name                      = "${var.cluster_name}-${each.value}-dlq"
  message_retention_seconds = 1209600 # 14 dias - tempo para investigar antes de perder a mensagem
}

resource "aws_sqs_queue" "saga" {
  for_each = local.saga_queues

  name                       = "${var.cluster_name}-${each.value}"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 345600 # 4 dias

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.saga_dlq[each.value].arn
    maxReceiveCount     = 5
  })
}

# Publica as URLs no SSM Parameter Store - mesmo padrao usado pelo
# DATABASE_URL em mecanica-db-infra-SOAT (ver RFC 0002) - para os 3
# microsservicos consumirem sem precisar hardcodar nada.
resource "aws_ssm_parameter" "saga_queue_url" {
  for_each = local.saga_queues

  name      = "/castor-garage/queues/${each.value}-url"
  type      = "String"
  value     = aws_sqs_queue.saga[each.value].url
  overwrite = true
}
