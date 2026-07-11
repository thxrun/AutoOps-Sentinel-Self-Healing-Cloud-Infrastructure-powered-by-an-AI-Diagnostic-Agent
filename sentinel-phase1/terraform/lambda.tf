data "archive_file" "collector_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/collector"
  output_path = "${path.module}/build/collector.zip"
}

resource "aws_iam_role" "collector_lambda_role" {
  name = "${var.project_name}-collector-lambda-role"

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

# Scoped to exactly what the Collector needs: run/read Logs Insights queries,
# read CloudWatch metrics, and write its own execution logs. Deliberately
# not using a broad managed policy here, unlike the EC2 role in iam.tf —
# this one is small enough to hand-write tightly.
resource "aws_iam_role_policy" "collector_lambda_policy" {
  name = "${var.project_name}-collector-lambda-policy"
  role = aws_iam_role.collector_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:StartQuery",
          "logs:GetQueryResults",
          "logs:StopQuery",
          "logs:DescribeLogGroups"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:GetMetricData",
          "cloudwatch:ListMetrics"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:*:log-group:/aws/lambda/${var.project_name}-collector:*"
      }
    ]
  })
}

resource "aws_lambda_function" "collector" {
  function_name    = "${var.project_name}-collector"
  role             = aws_iam_role.collector_lambda_role.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 256
  filename         = data.archive_file.collector_zip.output_path
  source_code_hash = data.archive_file.collector_zip.output_base64sha256

  environment {
    variables = {
      APP_LOG_GROUP    = "/sentinel/app"
      METRIC_NAMESPACE = "Sentinel"
      INSTANCE_ID      = aws_instance.sentinel_app.id
      LOOKBACK_MINUTES = tostring(var.collector_lookback_minutes)
    }
  }

  tags = {
    Project = var.project_name
  }
}

resource "aws_cloudwatch_log_group" "collector_lambda_logs" {
  name              = "/aws/lambda/${var.project_name}-collector"
  retention_in_days = 7

  tags = {
    Project = var.project_name
  }
}
