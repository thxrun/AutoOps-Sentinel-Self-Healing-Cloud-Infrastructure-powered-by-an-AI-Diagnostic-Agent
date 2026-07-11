# AutoOps Sentinel

**Self-Healing Cloud Infrastructure powered by an AI Diagnostic Agent**

AutoOps Sentinel is a DevOps automation system that detects infrastructure issues in real time, uses an AI agent to diagnose the root cause from logs and metrics, and either auto-remediates the issue or escalates it to a human with a precise, evidence-backed explanation — instead of a generic threshold alert.

Built entirely within the AWS Free Tier, using Terraform for infrastructure-as-code and Groq (Llama 3.3) as the reasoning engine for the AI agent.

---

## Table of Contents

- [Problem Statement](#problem-statement)
- [Solution Overview](#solution-overview)
- [Architecture](#architecture)
- [Tech Stack](#tech-stack)
- [Project Phases](#project-phases)
  - [Phase 1 — Infrastructure Foundation](#phase-1--infrastructure-foundation)
  - [Phase 2 — Detection Layer](#phase-2--detection-layer)
  - [Phase 3 — AI Agent Layer](#phase-3--ai-agent-layer)
  - [Phase 4 — Action & Notification Layer](#phase-4--action--notification-layer)
  - [Phase 5 — Dashboard, Polish & Demo](#phase-5--dashboard-polish--demo)
- [Safety Design](#safety-design)
- [Repository Structure](#repository-structure)
- [Setup & Deployment](#setup--deployment)
- [Demo Scenario](#demo-scenario)
- [Cost Notes (Free Tier)](#cost-notes-free-tier)
- [Future Improvements](#future-improvements)
- [Key Talking Points](#key-talking-points)

---

## Problem Statement

Small teams and solo developers rarely have 24/7 site-reliability coverage. When production infrastructure fails — a disk fills up, a process crashes, latency spikes, a security group is misconfigured — nobody notices until a user complains or a bill spikes. Traditional monitoring tools fire generic threshold alerts ("CPU > 80%") that tell you *something* is wrong but not *why*, leaving the human to manually dig through logs at the worst possible time.

## Solution Overview

AutoOps Sentinel closes that gap with a full **observe → diagnose → decide → act** loop:

1. **Observe** — CloudWatch continuously collects metrics and logs from the monitored EC2 instance.
2. **Diagnose** — When an alarm fires, an AI agent (via the Groq API) is handed the relevant logs and metrics and produces a structured root-cause analysis.
3. **Decide** — The agent classifies its recommended action as either safe to automate or requiring human approval.
4. **Act** — Safe actions are executed automatically via AWS Systems Manager (SSM); everything else is escalated to Slack/Telegram with the AI's full reasoning attached.

Every incident and every AI decision is logged, producing an auditable incident history — a genuine differentiator from a simple "LLM wrapper" project.

---

## Architecture

```
                        ┌───────────────────────┐
                        │   EC2 (t2.micro)       │
                        │   Sample App + Agent   │
                        │   CloudWatch Agent     │
                        └───────────┬────────────┘
                                    │ metrics + logs
                                    ▼
                        ┌───────────────────────┐
                        │   CloudWatch           │
                        │   Alarms + Log Groups  │
                        └───────────┬────────────┘
                                    │ alarm state change
                                    ▼
                        ┌───────────────────────┐
                        │   EventBridge Rule     │
                        └───────────┬────────────┘
                                    ▼
                        ┌───────────────────────┐
                        │  Lambda #1: Collector  │
                        │  Pulls logs + metrics  │
                        │  via Logs Insights     │
                        └───────────┬────────────┘
                                    ▼
                        ┌───────────────────────┐
                        │   Groq API (Llama 3.3) │
                        │   AI Diagnostic Agent  │
                        │   → structured JSON    │
                        └───────────┬────────────┘
                                    ▼
                        ┌───────────────────────┐
                        │  Lambda #2: Executor   │
                        │  Routes decision       │
                        └──────┬────────────┬────┘
                               ▼            ▼
                    ┌──────────────┐  ┌──────────────────┐
                    │  SSM Run Cmd │  │  SNS → Slack/     │
                    │  Auto-fix    │  │  Telegram alert   │
                    └──────────────┘  └──────────────────┘
                               │            │
                               ▼            ▼
                        ┌───────────────────────┐
                        │  DynamoDB              │
                        │  Incident history log  │
                        └───────────────────────┘
```

## Tech Stack

| Layer                  | Tool / Service                                  |
|-------------------------|--------------------------------------------------|
| Infrastructure as Code  | Terraform                                        |
| Compute                 | AWS EC2 (t2.micro, Free Tier)                    |
| Monitoring               | AWS CloudWatch (Metrics, Logs, Alarms, Insights) |
| Event Routing            | AWS EventBridge                                  |
| Serverless Compute       | AWS Lambda                                       |
| Remediation Execution    | AWS Systems Manager (SSM Run Command)            |
| Notifications             | AWS SNS → Slack / Telegram webhook              |
| Incident Storage          | AWS DynamoDB                                    |
| AI Reasoning Engine       | Groq API (Llama 3.3 70B)                        |
| Language                  | Python 3.12                                     |

---

## Project Phases

### Phase 1 — Infrastructure Foundation

**Goal:** A deployable, monitored EC2 instance running a sample application.

- Write Terraform for: VPC (or default VPC), EC2 instance (t2.micro), IAM roles and instance profile, security groups
- Deploy a small sample app (Flask or Node) with intentionally breakable endpoints:
  - `/fill-disk` — writes junk data to disk
  - `/crash` — kills the app process
  - `/spike-cpu` — busy-loop to spike CPU
- Install and configure the CloudWatch Agent on the instance to ship:
  - System logs and application logs
  - Custom metrics: disk usage, memory usage (CPU is available by default)
- **Deliverable:** `terraform apply` stands up the full environment; logs and metrics are visible in the CloudWatch console.

### Phase 2 — Detection Layer

**Goal:** The system notices problems within minutes, automatically.

- Create CloudWatch Alarms:
  - Disk usage > 85%
  - CPU utilization > 80%
  - Custom application health-check failure
- Create an EventBridge rule that triggers on alarm state change (`OK → ALARM`)
- Build **Lambda #1 (Collector)**:
  - Triggered by the EventBridge rule
  - Runs a CloudWatch Logs Insights query to pull the last N minutes of relevant logs
  - Pulls current metric values
  - Packages everything into a clean JSON payload for the AI agent
- **Deliverable:** Breaking something on the EC2 instance reliably triggers an alarm and produces a structured payload in Lambda logs.

### Phase 3 — AI Agent Layer

**Goal:** Turn raw logs and metrics into an actionable, structured diagnosis.

- Integrate the Groq API (Llama 3.3 70B) into Lambda
- Design a system prompt that forces structured JSON output:

```json
{
  "root_cause": "Disk usage exceeded 85% due to log file growth in /var/log/app",
  "confidence": 0.91,
  "suggested_action": "clear_tmp_and_rotate_logs",
  "action_type": "auto_safe",
  "reasoning": "Log directory grew 40MB in 10 minutes with repeated stack traces indicating a logging loop; safe to rotate and clear without data loss."
}
```

- Define a **fixed, version-controlled "safe action list"** up front (see [Safety Design](#safety-design)) — the agent may only select from this list for `auto_safe` classification; anything else is automatically routed to `needs_approval`
- **Deliverable:** Given a sample log payload, the agent reliably returns valid structured JSON with a sensible diagnosis.

### Phase 4 — Action & Notification Layer

**Goal:** Close the loop — act on safe issues, alert on everything else.

- Build **Lambda #2 (Executor)**:
  - Receives the agent's structured decision
  - If `action_type == "auto_safe"` → invokes an SSM Run Command document that executes the pre-approved remediation script on the EC2 instance
  - Always publishes an incident record to SNS regardless of action type
- Connect SNS to a Slack or Telegram webhook — the message includes root cause, action taken (or needed), and the AI's reasoning
- Write every incident (payload, diagnosis, action, outcome, timestamp) to a DynamoDB table
- **Deliverable:** Triggering `/fill-disk` results in either an automatic fix with a Slack confirmation, or a Slack alert requesting approval — and a row appears in DynamoDB either way.

### Phase 5 — Dashboard, Polish & Demo

**Goal:** Make the project easy to understand and demo in under two minutes.

- Build a lightweight dashboard (CloudWatch dashboard, or a small static page reading from DynamoDB) showing incident timeline and AI reasoning per incident
- Write a "chaos" script that triggers each failure mode on demand for reliable demos
- Record a short demo: break something → watch detection → watch AI diagnosis → watch auto-fix or Slack alert
- Finalize this README with an architecture diagram screenshot and demo GIF/video link
- **Deliverable:** A polished, demo-ready project with visual evidence of the full loop working end to end.

---

## Safety Design

Because this system can take real actions on real infrastructure, safety boundaries are defined explicitly and enforced in code — not left to the AI's judgment alone.

- **Fixed safe-action allowlist.** The agent can only trigger automated remediation for actions on a predefined list (e.g., restart a named service, clear `/tmp`, rotate logs). It cannot invent new actions to auto-execute.
- **Default to human approval.** Anything outside the allowlist — or anything the agent is not highly confident about — is always routed to Slack/Telegram for manual approval, never executed automatically.
- **Least-privilege IAM.** The Lambda execution role and the SSM automation role are scoped to only the specific actions and resources they need.
- **Full audit trail.** Every diagnosis and every action (automated or human-approved) is logged to DynamoDB with a timestamp, making the system's behavior fully reviewable after the fact.
- **Recommended rollout order.** Start with *everything* requiring human approval via a Slack button, and only promote specific, well-understood action types to full automation once they've proven reliable. This mirrors how real production auto-remediation systems are rolled out safely.

---

## Repository Structure

```
autoops-sentinel/
├── terraform/
│   ├── main.tf
│   ├── ec2.tf
│   ├── iam.tf
│   ├── cloudwatch.tf
│   ├── eventbridge.tf
│   ├── dynamodb.tf
│   └── variables.tf
├── lambda/
│   ├── collector/
│   │   └── handler.py
│   └── executor/
│       └── handler.py
├── agent/
│   ├── prompt_template.py
│   └── groq_client.py
├── app/
│   └── sample_app.py        # Breakable demo app
├── scripts/
│   ├── chaos.sh              # Triggers failure scenarios on demand
│   └── remediation/
│       ├── clear_tmp.sh
│       └── restart_service.sh
├── dashboard/
│   └── (dashboard code or CloudWatch dashboard JSON)
└── README.md
```

---

## Setup & Deployment

**Prerequisites**
- AWS account (Free Tier eligible)
- AWS CLI configured
- Terraform installed
- A Groq API key
- A Slack or Telegram webhook URL

**Steps**

```bash
# 1. Clone the repo
git clone <your-repo-url>
cd autoops-sentinel

# 2. Configure variables
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# edit terraform.tfvars with your AWS region, key pair name, Groq API key, webhook URL

# 3. Deploy infrastructure
cd terraform
terraform init
terraform plan
terraform apply

# 4. Deploy the sample app to EC2 (via SSM or user-data, per your Terraform config)

# 5. Trigger a test incident
../scripts/chaos.sh fill-disk

# 6. Watch it happen
#    - CloudWatch Alarm fires
#    - Lambda Collector runs
#    - AI agent diagnoses
#    - Slack/Telegram receives the alert or fix confirmation
#    - DynamoDB gets a new incident record
```

---

## Demo Scenario

1. Run `./scripts/chaos.sh fill-disk` to simulate a disk-space incident.
2. Within ~1–2 minutes, a CloudWatch Alarm transitions to `ALARM`.
3. Lambda Collector pulls the last 10 minutes of logs and current disk metrics.
4. The AI agent returns a diagnosis identifying runaway log growth as the root cause, with `action_type: auto_safe`.
5. Lambda Executor triggers an SSM command to rotate and clear logs.
6. A Slack message arrives: *"Incident resolved automatically — disk usage was at 91% due to unrotated application logs. Cleared and rotated. Root cause + action logged."*
7. The incident appears in the DynamoDB-backed dashboard with full reasoning attached.

---

## Cost Notes (Free Tier)

This project is designed to stay within AWS Free Tier limits for a portfolio project that isn't running constant production traffic:

- **EC2 t2.micro** — 750 free hours/month (first 12 months)
- **Lambda** — 1M free requests/month, well within demo usage
- **CloudWatch** — free tier covers basic alarms and a modest log volume; keep log retention short (e.g., 3–7 days) to stay well under limits
- **DynamoDB** — free tier covers 25GB storage and generous read/write capacity, far more than incident logging needs
- **SNS** — free tier covers more notifications than a demo project will generate
- **Groq API** — free tier is generous for intermittent, event-driven usage like this

Set a AWS Budget alert as a safety net regardless — good practice, and doubles as a nod to the CostGuard-style idea if you want to mention it in an interview.

---

## Future Improvements

- Promote more action types to `auto_safe` as confidence in the system grows
- Add a Slack "Approve / Reject" interactive button for `needs_approval` incidents, feeding the outcome back into the agent's future context (learning from human decisions)
- Extend the Collector to pull from multiple instances or an Auto Scaling Group
- Add anomaly detection (rather than static thresholds) to catch issues before they cross a hard alarm threshold
- Swap in a RAG layer over past incidents so the agent can reference "this happened before, here's what worked"
- Add a lightweight React dashboard instead of relying purely on CloudWatch/DynamoDB console views

---

## Key Talking Points

For interviews or write-ups, this project demonstrates:

- **End-to-end DevOps competency:** IaC, monitoring, event-driven architecture, IAM least-privilege, serverless compute, remediation automation
- **Genuine AI agency, not just an LLM wrapper:** the system observes, reasons, decides, and acts — a full agent loop with tool use (SSM) and explicit safety boundaries
- **Production-minded safety thinking:** a fixed allowlist for automated actions and a human-in-the-loop default reflects how real reliability engineering teams roll out automation
- **Auditable outcomes:** every decision is logged and explainable, not a black box
