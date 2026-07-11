# Disk and CPU dimensions are actually deterministic for this setup, so
# plain metric alarms are used instead of a metric_query/SEARCH expression
# (SEARCH is not supported on CloudWatch Metric Alarms — it's a
# GetMetricData/dashboard-only feature, which is what caused the earlier
# `SEARCH is not supported on Metric Alarms` apply error).
#
# - disk: cloudwatch/amazon-cloudwatch-agent.json sets "drop_device": true,
#   which removes the unpredictable `device` dimension. What's left
#   (path="/", fstype="xfs" on AL2023) is fixed by the AMI, not by boot-time
#   hardware naming.
# - cpu: the agent config has no "resources" list under "cpu", so it only
#   ever publishes one aggregated cpu_usage_active datapoint per instance —
#   no extra "cpu" dimension is added at all.
#
# If you ever change the agent config (e.g. add per-core CPU or multiple
# disk mounts), re-check the actual dimension set with:
#   aws cloudwatch list-metrics --namespace Sentinel --metric-name disk_used_percent
#   aws cloudwatch list-metrics --namespace Sentinel --metric-name cpu_usage_active

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
    fstype     = "xfs" # AL2023 default root filesystem
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
