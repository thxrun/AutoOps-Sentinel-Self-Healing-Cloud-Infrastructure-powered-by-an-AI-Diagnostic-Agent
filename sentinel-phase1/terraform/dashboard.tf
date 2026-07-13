resource "aws_cloudwatch_dashboard" "sentinel" {
  dashboard_name = "${var.project_name}-overview"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Disk Used % (threshold: ${var.disk_alarm_threshold}%)"
          region = var.aws_region
          view   = "timeSeries"
          stacked = false
          metrics = [
            ["Sentinel", "disk_used_percent", "InstanceId", aws_instance.sentinel_app.id, "path", "/", "fstype", var.disk_fstype]
          ]
          annotations = {
            horizontal = [
              {
                label = "Alarm threshold"
                value = var.disk_alarm_threshold
              }
            ]
          }
          period = 60
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "CPU Active % (threshold: ${var.cpu_alarm_threshold}%)"
          region = var.aws_region
          view   = "timeSeries"
          stacked = false
          metrics = [
            ["Sentinel", "cpu_usage_active", "InstanceId", aws_instance.sentinel_app.id, "cpu", "cpu-total"]
          ]
          annotations = {
            horizontal = [
              {
                label = "Alarm threshold"
                value = var.cpu_alarm_threshold
              }
            ]
          }
          period = 60
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 8
        height = 6
        properties = {
          title  = "Memory Used %"
          region = var.aws_region
          view   = "timeSeries"
          metrics = [
            ["Sentinel", "mem_used_percent", "InstanceId", aws_instance.sentinel_app.id]
          ]
          period = 60
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 6
        width  = 8
        height = 6
        properties = {
          title  = "Health Check Failures"
          region = var.aws_region
          view   = "timeSeries"
          metrics = [
            ["Sentinel", "HealthCheckFailure", "InstanceId", aws_instance.sentinel_app.id, { "stat" : "Maximum" }]
          ]
          period = 60
        }
      },
      {
        type   = "alarm"
        x      = 16
        y      = 6
        width  = 8
        height = 6
        properties = {
          title = "Alarm States"
          alarms = [
            aws_cloudwatch_metric_alarm.disk_high.arn,
            aws_cloudwatch_metric_alarm.cpu_high.arn,
            aws_cloudwatch_metric_alarm.health_check_failure.arn
          ]
        }
      },
      {
        type   = "log"
        x      = 0
        y      = 12
        width  = 24
        height = 8
        properties = {
          title  = "App Log (live tail)"
          region = var.aws_region
          view   = "table"
          query  = "SOURCE '/sentinel/app' | fields @timestamp, @message | sort @timestamp desc | limit 50"
        }
      }
    ]
  })
}

output "dashboard_url" {
  value = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.sentinel.dashboard_name}"
}