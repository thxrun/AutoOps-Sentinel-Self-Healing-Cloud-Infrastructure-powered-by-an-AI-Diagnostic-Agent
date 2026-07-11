output "instance_public_ip" {
  value = aws_instance.sentinel_app.public_ip
}

output "instance_id" {
  value = aws_instance.sentinel_app.id
}

output "app_url" {
  value = "http://${aws_instance.sentinel_app.public_ip}:${var.app_port}"
}

output "ssh_command" {
  value = "ssh -i <your-key>.pem ec2-user@${aws_instance.sentinel_app.public_ip}"
}

output "collector_lambda_name" {
  value = aws_lambda_function.collector.function_name
}

output "alarm_names" {
  value = [
    aws_cloudwatch_metric_alarm.disk_high.alarm_name,
    aws_cloudwatch_metric_alarm.cpu_high.alarm_name,
    aws_cloudwatch_metric_alarm.health_check_failure.alarm_name,
  ]
}
