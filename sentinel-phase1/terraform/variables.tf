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
  description = "EC2 instance type (t2.micro = free tier eligible)"
  type        = string
  default     = "t2.micro"
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

