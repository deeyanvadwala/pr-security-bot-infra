# ============ EVENT SIDE (Kenil) ============
# GitHub webhook -> API Gateway -> Lambda (verify HMAC, filter, RunTask on Fargate)

resource "aws_secretsmanager_secret" "bot" {
  name                    = "pr-security-bot/github"
  recovery_window_in_days = 0
  # Value is set with the CLI so it never lands in code or Terraform state.
}

data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/../lambda/handler.py"
  output_path = "${path.module}/build/handler.zip"
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/pr-bot-webhook"
  retention_in_days = 7
}

resource "aws_lambda_function" "webhook" {
  function_name    = "pr-bot-webhook"
  role             = data.aws_iam_role.lab.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 15

  environment {
    variables = {
      SECRET_ID       = aws_secretsmanager_secret.bot.name
      ALLOWED_REPO    = var.github_repo
      CLUSTER         = aws_ecs_cluster.scanner.name
      TASK_DEFINITION = aws_ecs_task_definition.scanner.arn
      CONTAINER_NAME  = "scanner"
      SUBNETS         = join(",", data.aws_subnets.default.ids)
      SECURITY_GROUP  = aws_security_group.scanner.id
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda]
}

resource "aws_apigatewayv2_api" "webhook" {
  name          = "pr-bot-webhook"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.webhook.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.webhook.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "webhook" {
  api_id    = aws_apigatewayv2_api.webhook.id
  route_key = "POST /webhook"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.webhook.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.webhook.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.webhook.execution_arn}/*/*"
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "pr-bot-webhook-errors"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.webhook.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
}

output "webhook_url" {
  value = "${aws_apigatewayv2_api.webhook.api_endpoint}/webhook"
}
