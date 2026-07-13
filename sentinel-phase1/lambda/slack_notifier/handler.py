"""
Sentinel Slack Notifier Lambda (Phase 4)

Subscribed to the same SNS topic as your email alerts. Forwards each
message to a Slack Incoming Webhook. Uses plain urllib, no external deps —
same approach as the Diagnostic Lambda's Gemini call, so no Lambda layer
or packaging step is needed.
"""

import json
import os
import urllib.request

SLACK_WEBHOOK_URL = os.environ["SLACK_WEBHOOK_URL"]


def handler(event, context):
    for record in event.get("Records", []):
        sns_message = record.get("Sns", {}).get("Message", "")
        subject = record.get("Sns", {}).get("Subject", "Sentinel Alert")

        slack_payload = {
            "text": f"*{subject}*\n```{sns_message}```"
        }

        req = urllib.request.Request(
            SLACK_WEBHOOK_URL,
            data=json.dumps(slack_payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as response:
                print(f"Slack response: {response.status}")
        except Exception as e:  # noqa: BLE001 - log, don't fail the whole batch
            print(f"Slack post failed: {e}")

    return {"statusCode": 200}
