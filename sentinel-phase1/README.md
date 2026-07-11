# Sentinel — Phase 1: Infrastructure Foundation

A `terraform apply`-able EC2 instance running a sample Flask app with
intentionally breakable endpoints, monitored by the CloudWatch Agent
(logs + disk/memory/cpu metrics).

## Structure

```
sentinel-phase1/
├── terraform/
│   ├── main.tf              # provider, default VPC/subnet/AMI lookups
│   ├── variables.tf
│   ├── iam.tf                # EC2 role + CloudWatchAgentServerPolicy + SSM
│   ├── security_groups.tf    # SSH (22) + app port ingress
│   ├── ec2.tf                 # the instance itself
│   ├── user_data.sh.tpl      # bootstrap: installs app + CW agent
│   └── outputs.tf
├── app/
│   ├── app.py                 # Flask app: /fill-disk /crash /spike-cpu
│   └── requirements.txt
└── cloudwatch/
    └── amazon-cloudwatch-agent.json
```

## Prerequisites

- AWS CLI configured (`aws configure`) with a user/role that can create
  EC2, IAM, and SG resources.
- An existing EC2 key pair in the target region (for SSH). Create one if
  you don't have it:
  ```bash
  aws ec2 create-key-pair --key-name sentinel-key \
    --query 'KeyMaterial' --output text > sentinel-key.pem
  chmod 400 sentinel-key.pem
  ```
- Terraform >= 1.5.

## Deploy

```bash
cd terraform

# Find your own public IP so you don't open SSH/app port to the world
MY_IP=$(curl -s https://checkip.amazonaws.com)/32

terraform init
terraform apply \
  -var="key_name=sentinel-key" \
  -var="ssh_ingress_cidr=${MY_IP}"
```

Or drop these into a `terraform.tfvars` file instead of passing `-var` flags:

```hcl
key_name         = "sentinel-key"
ssh_ingress_cidr = "203.0.113.10/32"
aws_region       = "ap-south-1"
```

## Verify

```bash
# From the outputs:
APP_URL=$(terraform output -raw app_url)

curl "$APP_URL/health"
curl "$APP_URL/fill-disk"
curl "$APP_URL/spike-cpu"
curl "$APP_URL/crash"      # process dies, systemd restarts it in ~3s
sleep 5
curl "$APP_URL/health"     # should be healthy again
```

Check CloudWatch:

```bash
# Log groups should show up within ~1-2 min of boot
aws logs describe-log-groups --log-group-name-prefix /sentinel

# Custom metrics
aws cloudwatch list-metrics --namespace Sentinel
```

Or just check the console: **CloudWatch → Log groups → /sentinel/app**
and **CloudWatch → Metrics → Sentinel**.

## Teardown (don't forget this)

```bash
terraform destroy \
  -var="key_name=sentinel-key" \
  -var="ssh_ingress_cidr=${MY_IP}"
```

t2.micro is free-tier eligible for the first 12 months of an AWS account,
but the CloudWatch Agent's custom metrics and log ingestion are **not**
part of the always-free tier past a small threshold — destroy the stack
when you're not actively demoing it.

## Design notes

- Default VPC is used deliberately to avoid NAT gateway costs — this is a
  demo/capstone environment, not production.
- IAM uses the AWS-managed `CloudWatchAgentServerPolicy` for simplicity.
  A natural "Phase 1.5" exercise: replace it with a hand-written
  least-privilege policy (just `logs:PutLogEvents`,
  `logs:CreateLogStream`, `cloudwatch:PutMetricData`, scoped by
  condition keys) and be ready to explain the trade-off in an interview.
- `SSM Core` policy is attached too, so you can `aws ssm start-session`
  into the box without opening port 22 at all if you want to tighten the
  security group further later.
- `/crash` calls `os._exit(1)` rather than raising, to simulate a hard
  process death — systemd's `Restart=always` is what brings it back, and
  that restart is itself something worth showing in your CloudWatch logs
  during a demo.
