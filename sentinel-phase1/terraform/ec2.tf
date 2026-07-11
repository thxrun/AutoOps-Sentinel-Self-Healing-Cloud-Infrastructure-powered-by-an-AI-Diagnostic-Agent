resource "aws_instance" "sentinel_app" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnet.first.id
  vpc_security_group_ids = [aws_security_group.sentinel_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name
  key_name               = var.key_name

  user_data = templatefile("${path.module}/user_data.sh.tpl", {
    app_py                        = file("${path.module}/../app/app.py")
    requirements_txt              = file("${path.module}/../app/requirements.txt")
    cwagent_json                  = file("${path.module}/../cloudwatch/amazon-cloudwatch-agent.json")
    health_check_sh                = file("${path.module}/../monitoring/health_check.sh")
    app_port                      = var.app_port
    aws_region                    = var.aws_region
    health_check_interval_seconds = var.health_check_interval_seconds
  })

  tags = {
    Name    = "${var.project_name}-app-instance"
    Project = var.project_name
  }
}
