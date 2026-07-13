#!/bin/bash
# Runs on a timer on the EC2 instance. Curls the app's own /health endpoint
# and publishes a 0/1 metric to CloudWatch so Phase 2 has something real to
# alarm on for "custom application health-check failure" — as opposed to
# EC2's built-in instance status checks, which only see the VM, not the app.

set -u

APP_PORT="${APP_PORT:-5000}"
NAMESPACE="Sentinel"
METRIC_NAME="HealthCheckFailure"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"

# Instance identity from IMDSv2 (no hardcoding, works on any instance)
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

if curl -sf "http://localhost:${APP_PORT}/health" > /dev/null; then
  VALUE=0
else
  VALUE=1
fi

aws cloudwatch put-metric-data \
  --region "$REGION" \
  --namespace "$NAMESPACE" \
  --metric-name "$METRIC_NAME" \
  --dimensions "InstanceId=${INSTANCE_ID}" \
  --value "$VALUE" \
  --unit Count
