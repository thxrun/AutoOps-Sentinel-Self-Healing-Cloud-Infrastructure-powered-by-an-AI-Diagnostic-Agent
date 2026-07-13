# Phase 3 — AI Diagnostic Agent
#
# The Collector Lambda (lambda.tf) invokes this one asynchronously at the end
# of its own handler, passing its JSON payload straight through as the event.
# This Lambda sends that payload to Gemini, gets back a structured diagnosis
# (including action_type), publishes it to SNS -> email, and hands the
# decision off to the Executor Lambda (executor.tf / Phase 4).

variable "gemini_model" {
  description = "Gemini model used by the diagnostic Lambda"
  type        = string
  default     = "gemini-3.5-flash"
}

variable "alert_email" {
  description = "Email address for Sentinel diagnostic alerts"
  type        = string
}

# ---- Secret: Gemini API key ----
# The key itself is NOT set here — Terraform only creates the secret
# container. Populate it once, out of band, so the key never touches state
# or version control:
#
#   aws secretsmanager put-secret-value \
#     --region us-east-1 \
#     --secret-id sentinel-gemini-api-key \
#     --secret-string "YOUR_GEMINI_API_KEY"

resource "aws_secretsmanager_secret" "gemini_api_key" {
  name        = "${var.project_name}-gemini-api-key"
  description = "Gemini API key used by the Diagnostic Lambda"

  tags = {
    Project = var.project_name
  }
}

# ---- SNS: diagnosis notifications ----

resource "aws_sns_topic" "diagnostic_alerts" {
  name = "${var.project_name}-diagnostic-alerts"

  tags = {
    Project = var.project_name
  }
}

resource "aws_sns_topic_subscription" "diagnostic_email" {
  topic_arn = aws_sns_topic.diagnostic_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ---- Diagnostic Lambda ----

data "archive_file" "diagnostic_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/diagnostic"
  output_path = "${path.module}/build/diagnostic.zip"
}

resource "aws_iam_role" "diagnostic_lambda_role" {
  name = "${var.project_name}-diagnostic-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Project = var.project_name
  }
}

resource "aws_iam_role_policy" "diagnostic_lambda_policy" {
  name = "${var.project_name}-diagnostic-lambda-policy"
  role = aws_iam_role.diagnostic_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.gemini_api_key.arn
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.diagnostic_alerts.arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:*:log-group:/aws/lambda/${var.project_name}-diagnostic:*"
      }
    ]
  })
}

resource "aws_lambda_function" "diagnostic" {
  function_name    = "${var.project_name}-diagnostic"
  role             = aws_iam_role.diagnostic_lambda_role.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 256
  filename         = data.archive_file.diagnostic_zip.output_path
  source_code_hash = data.archive_file.diagnostic_zip.output_base64sha256

  environment {
    variables = {
      GEMINI_SECRET_NAME    = aws_secretsmanager_secret.gemini_api_key.name
      GEMINI_MODEL          = var.gemini_model
      SNS_TOPIC_ARN         = aws_sns_topic.diagnostic_alerts.arn
      EXECUTOR_LAMBDA_NAME  = aws_lambda_function.executor.function_name
    }
  }

  tags = {
    Project = var.project_name
  }
}

resource "aws_cloudwatch_log_group" "diagnostic_lambda_logs" {
  name              = "/aws/lambda/${var.project_name}-diagnostic"
  retention_in_days = 7

  tags = {
    Project = var.project_name
  }
}

# ---- Let the Collector Lambda invoke this one directly ----

resource "aws_iam_role_policy" "collector_can_invoke_diagnostic" {
  name = "${var.project_name}-collector-invoke-diagnostic"
  role = aws_iam_role.collector_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["lambda:InvokeFunction"]
      Resource = aws_lambda_function.diagnostic.arn
    }]
  })
}

# ---- Let the Diagnostic Lambda invoke the Executor Lambda (Phase 4) ----

resource "aws_iam_role_policy" "diagnostic_can_invoke_executor" {
  name = "${var.project_name}-diagnostic-invoke-executor"
  role = aws_iam_role.diagnostic_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["lambda:InvokeFunction"]
      Resource = aws_lambda_function.executor.arn
    }]
  })
}
