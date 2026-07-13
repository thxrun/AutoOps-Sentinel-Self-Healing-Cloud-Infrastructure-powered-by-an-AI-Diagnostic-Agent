"""
Sentinel Collector Lambda (Phase 2)

Triggered by an EventBridge rule on CloudWatch Alarm state change (OK -> ALARM).
Pulls the last N minutes of app logs via CloudWatch Logs Insights, grabs the
current metric values relevant to whichever alarm fired, packages it all into
one JSON payload, and hands it off to the Diagnostic Lambda (Phase 3).
"""

import json
import os
import time
from datetime import datetime, timedelta, timezone

import boto3

logs_client = boto3.client("logs")
cw_client = boto3.client("cloudwatch")
lambda_client = boto3.client("lambda")

APP_LOG_GROUP = os.environ.get("APP_LOG_GROUP", "/sentinel/app")
METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", "Sentinel")
INSTANCE_ID = os.environ.get("INSTANCE_ID", "")
LOOKBACK_MINUTES = int(os.environ.get("LOOKBACK_MINUTES", "10"))
DIAGNOSTIC_LAMBDA_NAME = os.environ.get("DIAGNOSTIC_LAMBDA_NAME", "")

# Maps alarm name -> the metric this alarm actually watches, so we always
# fetch fresh data for the metric that triggered us (in addition to the
# full picture below).
ALARM_METRIC_MAP = {
    "sentinel-disk-high": "disk_used_percent",
    "sentinel-cpu-high": "cpu_usage_active",
    "sentinel-health-check-failure": "HealthCheckFailure",
}


def run_logs_insights_query(minutes: int) -> list:
    """Runs a Logs Insights query over the app log group and waits for results."""
    end_time = datetime.now(timezone.utc)
    start_time = end_time - timedelta(minutes=minutes)

    query = """
    fields @timestamp, @message
    | sort @timestamp desc
    | limit 100
    """

    start_response = logs_client.start_query(
        logGroupName=APP_LOG_GROUP,
        startTime=int(start_time.timestamp()),
        endTime=int(end_time.timestamp()),
        queryString=query,
    )
    query_id = start_response["queryId"]

    # Poll for completion — Logs Insights queries are async.
    for _ in range(15):
        result = logs_client.get_query_results(queryId=query_id)
        if result["status"] in ("Complete", "Failed", "Cancelled"):
            break
        time.sleep(1)
    else:
        result = {"results": [], "status": "Timeout"}

    events = []
    for row in result.get("results", []):
        entry = {field["field"]: field["value"] for field in row}
        events.append(entry)

    return events


def get_current_metric_value(metric_name: str) -> dict:
    """Fetches the most recent datapoint for a given Sentinel metric.

    CloudWatch requires an EXACT dimension match to find a metric — these
    have to mirror exactly what the CloudWatch Agent actually publishes
    (confirmed via `aws cloudwatch list-metrics`), or this silently returns
    zero datapoints instead of erroring.
    """
    end_time = datetime.now(timezone.utc)
    start_time = end_time - timedelta(minutes=5)

    if not INSTANCE_ID:
        dimensions = []
    elif metric_name == "disk_used_percent":
        dimensions = [
            {"Name": "InstanceId", "Value": INSTANCE_ID},
            {"Name": "path", "Value": "/"},
            {"Name": "fstype", "Value": "xfs"},
        ]
    elif metric_name == "cpu_usage_active":
        dimensions = [
            {"Name": "InstanceId", "Value": INSTANCE_ID},
            {"Name": "cpu", "Value": "cpu-total"},
        ]
    else:
        dimensions = [{"Name": "InstanceId", "Value": INSTANCE_ID}]

    try:
        response = cw_client.get_metric_statistics(
            Namespace=METRIC_NAMESPACE,
            MetricName=metric_name,
            Dimensions=dimensions,
            StartTime=start_time,
            EndTime=end_time,
            Period=60,
            Statistics=["Average", "Maximum"],
        )
        datapoints = sorted(
            response.get("Datapoints", []), key=lambda d: d["Timestamp"]
        )
        if not datapoints:
            return {"metric_name": metric_name, "value": None, "note": "no recent datapoints"}
        latest = datapoints[-1]
        return {
            "metric_name": metric_name,
            "average": latest.get("Average"),
            "maximum": latest.get("Maximum"),
            "timestamp": latest["Timestamp"].isoformat(),
        }
    except Exception as e:  # noqa: BLE001 - want this captured in the payload, not raised
        return {"metric_name": metric_name, "error": str(e)}


def handler(event, context):
    detail = event.get("detail", {})
    alarm_name = detail.get("alarmName", "unknown")
    alarm_state = detail.get("state", {}).get("value", "unknown")
    alarm_reason = detail.get("state", {}).get("reason", "")

    print(f"Collector triggered by alarm={alarm_name} state={alarm_state}")

    logs = run_logs_insights_query(LOOKBACK_MINUTES)

    triggering_metric = ALARM_METRIC_MAP.get(alarm_name)
    metrics = {}
    for metric_name in set(filter(None, [triggering_metric, "disk_used_percent", "cpu_usage_active", "HealthCheckFailure"])):
        metrics[metric_name] = get_current_metric_value(metric_name)

    payload = {
        "alarm_name": alarm_name,
        "alarm_state": alarm_state,
        "alarm_reason": alarm_reason,
        "instance_id": INSTANCE_ID,
        "collected_at": datetime.now(timezone.utc).isoformat(),
        "lookback_minutes": LOOKBACK_MINUTES,
        "metrics": metrics,
        "log_event_count": len(logs),
        "logs": logs,
    }

    print(json.dumps(payload, default=str))

    if DIAGNOSTIC_LAMBDA_NAME:
        try:
            lambda_client.invoke(
                FunctionName=DIAGNOSTIC_LAMBDA_NAME,
                InvocationType="Event",
                Payload=json.dumps(payload, default=str).encode("utf-8"),
            )
            print(f"Invoked diagnostic lambda: {DIAGNOSTIC_LAMBDA_NAME}")
        except Exception as e:  # noqa: BLE001 — don't break the collector's own result
            print(f"Diagnostic invoke failed: {e}")
    else:
        print("DIAGNOSTIC_LAMBDA_NAME not set — skipping diagnostic invoke")

    return payload
