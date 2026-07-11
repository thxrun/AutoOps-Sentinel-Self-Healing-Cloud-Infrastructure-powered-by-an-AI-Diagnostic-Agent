# IAM role the EC2 instance assumes. Scoped to just what CloudWatch Agent needs:
# PutMetricData, log group/stream creation, and pushing log events.
# Using the AWS-managed policy keeps this simple and auditable — swap for a
# tighter custom policy later if you want to demo least-privilege design.

resource "aws_iam_role" "ec2_cw_role" {
  name = "${var.project_name}-ec2-cwagent-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Project = var.project_name
  }
}

resource "aws_iam_role_policy_attachment" "cwagent_server_policy" {
  role       = aws_iam_role.ec2_cw_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Optional but useful: lets you SSM into the box without opening SSH at all.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_cw_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ec2_cw_role.name
}
