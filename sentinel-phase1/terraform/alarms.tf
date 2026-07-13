# CloudWatch Agent publishes disk/cpu metrics with extra dimensions
# (device, fstype, cpu) beyond just InstanceId. Alarms require an exact
# dimension match — SEARCH expressions aren't supported on alarms (only
# dashboards), so these use plain metric blocks with the dimensions
# confirmed from Phase 1's `aws cloudwatch list-metrics` output.
resource "aws_cloudwatch_metric_alarm" "disk_high" {
  alarm_name          = "sentinel-disk-high"
  alarm_description   = "Disk usage above ${var.disk_alarm_threshold}% on ${aws_instance.sentinel_app.id}"
  namespace           = "Sentinel"
  metric_name         = "disk_used_percent"
  statistic           = "Average"
  period              = 60
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.disk_alarm_threshold
  evaluation_periods  = 2
  treat_missing_data  = "notBreaching"

  dimensions = {
    InstanceId = aws_instance.sentinel_app.id
    path       = "/"
    fstype     = var.disk_fstype
  }

  tags = {
    Project = var.project_name
  }
}
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "sentinel-cpu-high"
  alarm_description   = "CPU usage above ${var.cpu_alarm_threshold}% on ${aws_instance.sentinel_app.id}"
  namespace           = "Sentinel"
  metric_name         = "cpu_usage_active"
  statistic           = "Average"
  period              = 60
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.cpu_alarm_threshold
  evaluation_periods  = 2
  treat_missing_data  = "notBreaching"

  dimensions = {
    InstanceId = aws_instance.sentinel_app.id
    cpu        = "cpu-total"
  }

  tags = {
    Project = var.project_name
  }
}

# Published by monitoring/health_check.sh on a timer (see user_data.sh.tpl).
# Dimensions are known exactly here, so this is a plain metric alarm.
resource "aws_cloudwatch_metric_alarm" "health_check_failure" {
  alarm_name          = "sentinel-health-check-failure"
  alarm_description   = "App /health endpoint failed on ${aws_instance.sentinel_app.id}"
  namespace           = "Sentinel"
  metric_name         = "HealthCheckFailure"
  statistic           = "Maximum"
  period              = 60
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"

  dimensions = {
    InstanceId = aws_instance.sentinel_app.id
  }

  tags = {
    Project = var.project_name
  }
}
