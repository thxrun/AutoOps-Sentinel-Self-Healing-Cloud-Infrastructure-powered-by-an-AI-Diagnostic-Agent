"""
Sentinel Diagnostic Lambda (Phase 3 + Phase 4 handoff)

Invoked directly by the Collector Lambda at the end of its handler, passing
along the same JSON payload the Collector already assembled (alarm info,
current metric values, recent app logs). This Lambda:

  1. Sends that payload to Gemini with a diagnosis prompt.
  2. Parses the structured JSON response (root cause / confidence /
     remediation / severity / action_type).
  3. Publishes a formatted summary to SNS, which fans out to email (and,
     once wired, Slack).
  4. Hands the structured decision off to the Executor Lambda (Phase 4),
     which is the only thing allowed to actually run remediation.
"""

import json
import os
import urllib.request
import urllib.error

import boto3

secrets_client = boto3.client("secretsmanager")
sns_client = boto3.client("sns")
lambda_client = boto3.client("lambda")

GEMINI_SECRET_NAME = os.environ["GEMINI_SECRET_NAME"]
GEMINI_MODEL = os.environ.get("GEMINI_MODEL", "gemini-3.5-flash")
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
EXECUTOR_LAMBDA_NAME = os.environ.get("EXECUTOR_LAMBDA_NAME", "")

GEMINI_ENDPOINT = (
    f"https://generativelanguage.googleapis.com/v1beta/models/{GEMINI_MODEL}:generateContent"
)

# Cached across warm invocations so we don't hit Secrets Manager every time.
_cached_api_key = None

DIAGNOSIS_SCHEMA = {
    "type": "object",
    "properties": {
        "root_cause": {"type": "string"},
        "confidence": {"type": "string", "enum": ["low", "medium", "high"]},
        "suggested_remediation": {"type": "string"},
        "severity": {"type": "string", "enum": ["low", "medium", "high", "critical"]},
        "action_type": {"type": "string", "enum": ["auto_safe", "needs_approval"]},
    },
    "required": ["root_cause", "confidence", "suggested_remediation", "severity", "action_type"],
}

PROMPT_TEMPLATE = """You are a site-reliability diagnostic assistant for a small demo
EC2 stack called "Sentinel". An alarm just fired. Below is the structured payload
collected at alarm time: the alarm that triggered, current metric values, and the
most recent application log lines.

Analyze it and produce a diagnosis. Be concise and concrete — this is read by a
human getting a paged notification, not a report.

ALARM PAYLOAD:
{payload_json}

Respond with your diagnosis of the root cause, how confident you are given the
evidence available, a specific and actionable suggested remediation step, and how
severe this looks.

Also classify action_type:
- "auto_safe" ONLY if this is clearly caused by junk files written by the
  /fill-disk demo endpoint filling /var/sentinel-fill — the one pre-approved
  automatic fix is deleting those files.
- "needs_approval" for every other case (CPU spikes, crashes, anything
  ambiguous or where you're not highly confident). When in doubt, choose
  needs_approval.
"""


def _get_api_key() -> str:
    global _cached_api_key
    if _cached_api_key:
        return _cached_api_key
    secret = secrets_client.get_secret_value(SecretId=GEMINI_SECRET_NAME)
    _cached_api_key = secret["SecretString"]
    return _cached_api_key


def call_gemini(payload: dict) -> dict:
    prompt = PROMPT_TEMPLATE.format(payload_json=json.dumps(payload, default=str, indent=2))

    request_body = {
        "contents": [{"parts": [{"text": prompt}]}],
        "generationConfig": {
            "response_mime_type": "application/json",
            "response_schema": DIAGNOSIS_SCHEMA,
            "temperature": 0.2,
        },
    }

    req = urllib.request.Request(
        url=f"{GEMINI_ENDPOINT}?key={_get_api_key()}",
        data=json.dumps(request_body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=25) as resp:
            response_data = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        error_body = e.read().decode("utf-8")
        raise RuntimeError(f"Gemini API error {e.code}: {error_body}") from e

    text = response_data["candidates"][0]["content"]["parts"][0]["text"]
    return json.loads(text)


def format_email_body(alarm_payload: dict, diagnosis: dict) -> str:
    return f"""Sentinel Diagnostic Report
==========================

Alarm:        {alarm_payload.get('alarm_name')}
State:        {alarm_payload.get('alarm_state')}
Instance:     {alarm_payload.get('instance_id')}
Collected at: {alarm_payload.get('collected_at')}

--- Diagnosis (Gemini) ---
Severity:     {diagnosis.get('severity')}
Confidence:   {diagnosis.get('confidence')}
Action type:  {diagnosis.get('action_type')}

Root cause:
{diagnosis.get('root_cause')}

Suggested remediation:
{diagnosis.get('suggested_remediation')}

--- Raw alarm reason ---
{alarm_payload.get('alarm_reason')}
"""


def handler(event, context):
    # event is the Collector's payload dict, passed directly via Lambda invoke.
    alarm_payload = event

    print(f"Diagnostic Lambda invoked for alarm={alarm_payload.get('alarm_name')}")

    try:
        diagnosis = call_gemini(alarm_payload)
    except Exception as e:  # noqa: BLE001 — want this in the notification, not just a crash
        print(f"Gemini call failed: {e}")
        diagnosis = {
            "root_cause": "Diagnostic agent failed to produce an analysis.",
            "confidence": "low",
            "suggested_remediation": f"Investigate manually. Error: {e}",
            "severity": "medium",
            "action_type": "needs_approval",
        }

    subject = f"[Sentinel] {alarm_payload.get('alarm_name', 'alarm')} — {diagnosis.get('severity', 'unknown').upper()}"
    body = format_email_body(alarm_payload, diagnosis)

    sns_client.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject=subject[:100],  # SNS subject cap
        Message=body,
    )

    if EXECUTOR_LAMBDA_NAME:
        try:
            lambda_client.invoke(
                FunctionName=EXECUTOR_LAMBDA_NAME,
                InvocationType="Event",  # async, same as Collector -> Diagnostic
                Payload=json.dumps({
                    "alarm_name": alarm_payload.get("alarm_name"),
                    "instance_id": alarm_payload.get("instance_id"),
                    "diagnosis": diagnosis,
                }, default=str).encode("utf-8"),
            )
            print(f"Invoked executor lambda: {EXECUTOR_LAMBDA_NAME}")
        except Exception as e:  # noqa: BLE001 — don't break the email path
            print(f"Executor invoke failed: {e}")
    else:
        print("EXECUTOR_LAMBDA_NAME not set — skipping executor invoke")

    result = {"alarm_name": alarm_payload.get("alarm_name"), "diagnosis": diagnosis}
    print(json.dumps(result, default=str))
    return result
