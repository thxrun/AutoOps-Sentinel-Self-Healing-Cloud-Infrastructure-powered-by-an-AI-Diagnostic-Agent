# ---- Variables specific to Phase 4 ----
# Add these to variables.tf, or leave here in a separate file — Terraform
# doesn't care which .tf file a variable block lives in.

variable "slack_webhook_url" {
  description = "Slack Incoming Webhook URL. Leave blank to skip Slack wiring."
  type        = string
  default     = ""
  sensitive   = true
}

# ---- DynamoDB: incident history ----

resource "aws_dynamodb_table" "incidents" {
  name         = "${var.project_name}-incidents"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "incident_id"

  attribute {
    name = "incident_id"
    type = "S"
  }

  tags = {
    Project = var.project_name
  }
}

# ---- SSM Document: the ONLY pre-approved auto-remediation action ----

resource "aws_ssm_document" "cleanup_fill_disk" {
  name          = "${var.project_name}-cleanup-fill-disk"
  document_type = "Command"
  document_format = "YAML"

  content = yamlencode({
    schemaVersion = "2.2"
    description   = "Sentinel pre-approved remediation: delete /fill-disk junk files"
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "cleanupFillDisk"
        inputs = {
          runCommand = [file("${path.module}/../monitoring/remediation/cleanup_fill_disk.sh")]
        }
      }
    ]
  })

  tags = {
    Project = var.project_name
  }
}

# ---- Executor Lambda ----

data "archive_file" "executor_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/executor"
  output_path = "${path.module}/build/executor.zip"
}

resource "aws_iam_role" "executor_lambda_role" {
  name = "${var.project_name}-executor-lambda-role"

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

resource "aws_iam_role_policy" "executor_lambda_policy" {
  name = "${var.project_name}-executor-lambda-policy"
  role = aws_iam_role.executor_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:SendCommand", "ssm:GetCommandInvocation"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
        Resource = aws_dynamodb_table.incidents.arn
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = "*" # scope this to your actual SNS topic ARN once you paste it in
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.aws_region}:*:log-group:/aws/lambda/${var.project_name}-executor:*"
      }
    ]
  })
}

resource "aws_lambda_function" "executor" {
  function_name    = "${var.project_name}-executor"
  role             = aws_iam_role.executor_lambda_role.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 256
  filename         = data.archive_file.executor_zip.output_path
  source_code_hash = data.archive_file.executor_zip.output_base64sha256

  environment {
    variables = {
      INCIDENTS_TABLE  = aws_dynamodb_table.incidents.name
      SSM_DOCUMENT_NAME = aws_ssm_document.cleanup_fill_disk.name
      SNS_TOPIC_ARN     = "" # PASTE your existing sentinel-diagnostic-alerts topic ARN here
    }
  }

  tags = {
    Project = var.project_name
  }
}

resource "aws_cloudwatch_log_group" "executor_lambda_logs" {
  name              = "/aws/lambda/${var.project_name}-executor"
  retention_in_days = 7

  tags = {
    Project = var.project_name
  }
}

# ---- Slack notifier Lambda, subscribed to your existing SNS topic ----

data "archive_file" "slack_notifier_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/slack_notifier"
  output_path = "${path.module}/build/slack_notifier.zip"
}

resource "aws_iam_role" "slack_notifier_role" {
  name = "${var.project_name}-slack-notifier-role"

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

resource "aws_iam_role_policy" "slack_notifier_policy" {
  name = "${var.project_name}-slack-notifier-policy"
  role = aws_iam_role.slack_notifier_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "arn:aws:logs:${var.aws_region}:*:log-group:/aws/lambda/${var.project_name}-slack-notifier:*"
    }]
  })
}

resource "aws_lambda_function" "slack_notifier" {
  function_name    = "${var.project_name}-slack-notifier"
  role             = aws_iam_role.slack_notifier_role.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 15
  memory_size      = 128
  filename         = data.archive_file.slack_notifier_zip.output_path
  source_code_hash = data.archive_file.slack_notifier_zip.output_base64sha256

  environment {
    variables = {
      SLACK_WEBHOOK_URL = var.slack_webhook_url
    }
  }

  tags = {
    Project = var.project_name
  }
}

# PASTE your existing SNS topic resource name/ARN in place of the
# placeholder below — this subscribes Slack notifier to the SAME topic
# your email already listens to.
#
# resource "aws_sns_topic_subscription" "slack" {
#   topic_arn = "<your sentinel-diagnostic-alerts ARN>"
#   protocol  = "lambda"
#   endpoint  = aws_lambda_function.slack_notifier.arn
# }
#
# resource "aws_lambda_permission" "allow_sns_slack" {
#   statement_id  = "AllowSNSInvoke"
#   action        = "lambda:InvokeFunction"
#   function_name = aws_lambda_function.slack_notifier.function_name
#   principal     = "sns.amazonaws.com"
#   source_arn    = "<your sentinel-diagnostic-alerts ARN>"
# }
