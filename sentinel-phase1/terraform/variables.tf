variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefix used for naming all resources"
  type        = string
  default     = "sentinel"
}

variable "instance_type" {
  description = "EC2 instance type. Free-tier eligibility varies by account age — check with: aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true"
  type        = string
  default     = "t3.micro"
}

variable "ssh_ingress_cidr" {
  description = "CIDR allowed to SSH into the instance. Set to your own IP/32, not 0.0.0.0/0."
  type        = string
  default     = "0.0.0.0/0" # override this in terraform.tfvars
}

variable "app_port" {
  description = "Port the Flask app listens on"
  type        = number
  default     = 5000
}

variable "key_name" {
  description = "Name of an existing EC2 key pair for SSH access"
  type        = string
}

# ---- Phase 2: Detection Layer ----

variable "disk_alarm_threshold" {
  description = "Disk used percent above which the disk alarm fires"
  type        = number
  default     = 85
}

variable "cpu_alarm_threshold" {
  description = "CPU active percent above which the cpu alarm fires"
  type        = number
  default     = 80
}

variable "health_check_interval_seconds" {
  description = "How often the on-instance health-check script runs and publishes its metric"
  type        = number
  default     = 60
}

variable "collector_lookback_minutes" {
  description = "How many minutes of logs the Collector Lambda pulls when an alarm fires"
  type        = number
  default     = 10
}
