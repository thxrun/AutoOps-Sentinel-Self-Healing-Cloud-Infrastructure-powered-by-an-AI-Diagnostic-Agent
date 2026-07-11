#!/bin/bash
set -euxo pipefail

# ---- 1. Base packages ----
dnf update -y
dnf install -y python3-pip amazon-cloudwatch-agent

# ---- 2. Drop in the app ----
mkdir -p /opt/sentinel-app
cat > /opt/sentinel-app/app.py << 'APP_EOF'
${app_py}
APP_EOF

cat > /opt/sentinel-app/requirements.txt << 'REQ_EOF'
${requirements_txt}
REQ_EOF

pip3 install -r /opt/sentinel-app/requirements.txt

# App writes its own log file here; CW agent tails this path (see config below).
mkdir -p /var/log/sentinel-app
touch /var/log/sentinel-app/app.log
chmod 666 /var/log/sentinel-app/app.log

# ---- 3. systemd service so the app survives reboots / /crash restarts ----
cat > /etc/systemd/system/sentinel-app.service << 'SVC_EOF'
[Unit]
Description=Sentinel sample Flask app
After=network.target

[Service]
WorkingDirectory=/opt/sentinel-app
ExecStart=/usr/bin/python3 /opt/sentinel-app/app.py
Restart=always
RestartSec=3
Environment=APP_PORT=${app_port}
StandardOutput=append:/var/log/sentinel-app/app.log
StandardError=append:/var/log/sentinel-app/app.log

[Install]
WantedBy=multi-user.target
SVC_EOF

systemctl daemon-reload
systemctl enable sentinel-app
systemctl start sentinel-app

# ---- 4. CloudWatch Agent config + start ----
mkdir -p /opt/aws/amazon-cloudwatch-agent/etc
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'CW_EOF'
${cwagent_json}
CW_EOF

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -s \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
