# Phase 4 — Manual Wiring Instructions

I built Phase 4 as new, additive files (`terraform/executor.tf`,
`lambda/executor/`, `lambda/slack_notifier/`,
`monitoring/remediation/cleanup_fill_disk.sh`) so nothing in your existing
Phase 2/3 setup gets touched or risked. But 3 small connections need to be
made by hand, because I don't have your actual current
`lambda/diagnostic/handler.py` or `terraform/diagnostic.tf` content (you've
made several manual fixes to this project I never saw — the `/diskinfo`
endpoint, `FILL_DIR` change, `drop_device` config, the SNS/Secrets Manager
setup). Rather than guess and risk another region/state-style mismatch,
here's exactly what to change and where.

## 1. Give the Diagnostic Lambda's Gemini prompt an `action_type` field

Find where your diagnostic Lambda builds the prompt sent to Gemini and asks
for structured JSON back (root_cause/confidence/severity/etc). Add one more
required field to that schema:

```
"action_type": "auto_safe" if the issue is a disk-fill situation caused by
  /fill-disk junk files (the only pre-approved safe remediation), otherwise
  "needs_approval" for everything else (cpu spikes, crashes, anything
  ambiguous).
```

Tell Gemini explicitly in the prompt that `action_type` must be exactly one
of those two strings — otherwise you'll get free-text variations that break
the Executor's `if action_type == "auto_safe"` check.

## 2. Have the Diagnostic Lambda invoke Executor after it gets Gemini's response

Wherever your diagnostic handler currently builds its SNS message and
publishes it, add an additional call (this mirrors how Collector already
invokes Diagnostic — same pattern):

```python
import boto3
lambda_client = boto3.client("lambda")

lambda_client.invoke(
    FunctionName=os.environ["EXECUTOR_LAMBDA_NAME"],
    InvocationType="Event",  # async, same as Collector -> Diagnostic
    Payload=json.dumps({
        "alarm_name": alarm_name,       # whatever variable holds this
        "instance_id": instance_id,     # whatever variable holds this
        "diagnosis": diagnosis_dict,    # the parsed Gemini JSON response
    }).encode("utf-8"),
)
```

Wrap it in a try/except so a failure here doesn't break your already-working
email path.

**Terraform side** — add to `terraform/diagnostic.tf`:
- An `EXECUTOR_LAMBDA_NAME` environment variable on your diagnostic Lambda
  resource, set to `aws_lambda_function.executor.function_name`
- A statement on the diagnostic Lambda's IAM role policy allowing:
  ```hcl
  {
    Effect   = "Allow"
    Action   = ["lambda:InvokeFunction"]
    Resource = aws_lambda_function.executor.arn
  }
  ```

## 3. Wire your existing SNS topic into executor.tf and Slack

Open `terraform/executor.tf` and fill in the two placeholders:

- In `aws_lambda_function.executor`'s environment block, set
  `SNS_TOPIC_ARN` to your real topic ARN (the one email is already
  subscribed to — `sentinel-diagnostic-alerts` per your handoff notes).
- Uncomment the `aws_sns_topic_subscription.slack` and
  `aws_lambda_permission.allow_sns_slack` blocks at the bottom of the file,
  and replace `<your sentinel-diagnostic-alerts ARN>` in both with the same
  real ARN.

If you'd rather reference it properly instead of hardcoding the ARN string,
and your existing topic resource is named e.g.
`aws_sns_topic.diagnostic_alerts` in `diagnostic.tf`, just use
`aws_sns_topic.diagnostic_alerts.arn` in both places instead — cleaner,
and Terraform will manage the dependency automatically.

## 4. Get a Slack webhook URL (skip if using Telegram instead)

Slack → your workspace → Apps → search "Incoming Webhooks" → add to a
channel → copy the webhook URL. Then apply with:

```cmd
terraform apply -var="key_name=sentinel-key" -var="ssh_ingress_cidr=0.0.0.0/0" -var="slack_webhook_url=https://hooks.slack.com/services/XXX/YYY/ZZZ"
```

## After wiring — test the full loop

```cmd
curl %APP_URL%/fill-disk
```
(repeat until disk crosses 85%, same as Phase 2 testing)

Then check:
```cmd
aws dynamodb scan --region us-east-1 --table-name sentinel-incidents --query "Items[-1]"
aws logs tail /aws/lambda/sentinel-executor --region us-east-1 --since 10m
```
And check Slack for the message, plus SSM command history:
```cmd
aws ssm list-commands --region us-east-1 --query "Commands[0].{Status:Status,Doc:DocumentName}"
```
