"""
Sentinel Executor Lambda (Phase 4)

Invoked directly by the Diagnostic Lambda with its structured decision:
{
  "alarm_name": ...,
  "instance_id": ...,
  "diagnosis": {
    "root_cause": ...,
    "severity": ...,
    "confidence": ...,
    "suggested_remediation": ...,
    "action_type": "auto_safe" | "needs_approval"
  }
}

If action_type == "auto_safe", runs the pre-approved SSM document.
Always writes an incident row to DynamoDB and publishes to SNS, regardless
of whether an automatic action was taken.
"""

import json
import os
import time
from datetime import datetime, timezone

import boto3

ssm_client = boto3.client("ssm")
dynamodb = boto3.resource("dynamodb")
sns_client = boto3.client("sns")

TABLE_NAME = os.environ["INCIDENTS_TABLE"]
SSM_DOCUMENT_NAME = os.environ["SSM_DOCUMENT_NAME"]
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]

table = dynamodb.Table(TABLE_NAME)


def run_auto_remediation(instance_id: str) -> dict:
    """Fires the pre-approved SSM Run Command and waits briefly for a result."""
    try:
        response = ssm_client.send_command(
            InstanceIds=[instance_id],
            DocumentName=SSM_DOCUMENT_NAME,
            Comment="Sentinel auto-remediation: disk cleanup",
        )
        command_id = response["Command"]["CommandId"]

        # Give it a few seconds and check status once — this is a demo-scale
        # project, not a long-running orchestration, so we don't need a full
        # poll loop here.
        time.sleep(5)
        invocation = ssm_client.get_command_invocation(
            CommandId=command_id, InstanceId=instance_id
        )
        return {
            "executed": True,
            "command_id": command_id,
            "status": invocation.get("Status"),
            "output": invocation.get("StandardOutputContent", "")[:1000],
        }
    except Exception as e:  # noqa: BLE001 - capture in the record, don't crash
        return {"executed": False, "error": str(e)}


def handler(event, context):
    diagnosis = event.get("diagnosis", {})
    action_type = diagnosis.get("action_type", "needs_approval")
    instance_id = event.get("instance_id", "")
    alarm_name = event.get("alarm_name", "unknown")

    action_result = {"action_type": action_type}

    if action_type == "auto_safe" and instance_id:
        action_result["remediation"] = run_auto_remediation(instance_id)
    else:
        action_result["remediation"] = {"executed": False, "reason": "requires human approval"}

    incident = {
        "incident_id": f"{alarm_name}-{int(time.time())}",
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "alarm_name": alarm_name,
        "instance_id": instance_id,
        "diagnosis": diagnosis,
        "action_taken": action_result,
        "raw_event": event,
    }

    table.put_item(Item=json.loads(json.dumps(incident), parse_float=str))

    action_summary = (
        "Auto-remediation executed"
        if action_result["remediation"].get("executed")
        else "Manual approval needed"
    )

    message = (
        f"Sentinel Incident\n"
        f"==================\n"
        f"Alarm: {alarm_name}\n"
        f"Instance: {instance_id}\n"
        f"Severity: {diagnosis.get('severity', 'unknown')}\n"
        f"Confidence: {diagnosis.get('confidence', 'unknown')}\n\n"
        f"Root cause:\n{diagnosis.get('root_cause', 'n/a')}\n\n"
        f"Action: {action_summary}\n"
        f"Suggested remediation:\n{diagnosis.get('suggested_remediation', 'n/a')}\n"
    )

    sns_client.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject=f"Sentinel Incident: {alarm_name}",
        Message=message,
    )

    print(json.dumps(incident, default=str))
    return incident
