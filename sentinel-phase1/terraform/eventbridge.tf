resource "aws_cloudwatch_event_rule" "alarm_to_collector" {
  name        = "${var.project_name}-alarm-state-change"
  description = "Fires when any Sentinel alarm transitions into ALARM state"

  event_pattern = jsonencode({
    source      = ["aws.cloudwatch"]
    detail-type = ["CloudWatch Alarm State Change"]
    detail = {
      alarmName = [
        aws_cloudwatch_metric_alarm.disk_high.alarm_name,
        aws_cloudwatch_metric_alarm.cpu_high.alarm_name,
        aws_cloudwatch_metric_alarm.health_check_failure.alarm_name,
      ]
      state = {
        value = ["ALARM"]
      }
    }
  })

  tags = {
    Project = var.project_name
  }
}

resource "aws_cloudwatch_event_target" "collector_target" {
  rule      = aws_cloudwatch_event_rule.alarm_to_collector.name
  target_id = "${var.project_name}-collector"
  arn       = aws_lambda_function.collector.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.collector.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.alarm_to_collector.arn
}
