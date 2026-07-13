import logging
import multiprocessing
import os
import shutil
import subprocess
import sys
import time

from flask import Flask, jsonify

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("sentinel-app")

app = Flask(__name__)

FILL_DIR = "/var/sentinel-fill"
FILL_FILE = os.path.join(FILL_DIR, "junk.bin")
CHUNK_SIZE_MB = 50  # each hit appends 50MB


@app.route("/")
def index():
    return jsonify(status="ok", app="sentinel-sample-app")


@app.route("/health")
def health():
    return jsonify(status="healthy"), 200


@app.route("/fill-disk")
def fill_disk():
    """Appends junk data to disk to simulate a disk-pressure incident."""
    os.makedirs(FILL_DIR, exist_ok=True)
    with open(FILL_FILE, "ab") as f:
        f.write(os.urandom(CHUNK_SIZE_MB * 1024 * 1024))
    log.warning("fill-disk hit: wrote %sMB to %s", CHUNK_SIZE_MB, FILL_FILE)
    return jsonify(status="wrote_junk", chunk_mb=CHUNK_SIZE_MB, file=FILL_FILE)


@app.route("/diskinfo")
def diskinfo():
    total, used, free = shutil.disk_usage("/")
    return jsonify(
        total_gb=round(total / (1024**3), 2),
        used_gb=round(used / (1024**3), 2),
        free_gb=round(free / (1024**3), 2),
        used_percent=round(used / total * 100, 2),
    ), 200


@app.route("/ssmcheck")
def ssmcheck():
    result = {}
    try:
        status = subprocess.run(
            ["systemctl", "status", "amazon-ssm-agent"],
            capture_output=True, text=True, timeout=5
        )
        result["agent_status"] = (status.stdout + status.stderr)[-2000:]
    except FileNotFoundError:
        result["agent_status"] = "amazon-ssm-agent unit not found"
    except Exception as e:
        result["agent_status_error"] = str(e)

    try:
        conn = subprocess.run(
            ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
             "--max-time", "5", "https://ssm.us-east-1.amazonaws.com"],
            capture_output=True, text=True, timeout=8
        )
        result["ssm_endpoint_http_code"] = conn.stdout.strip()
    except Exception as e:
        result["ssm_endpoint_error"] = str(e)

    try:
        ver = subprocess.run(
            ["amazon-ssm-agent", "--version"],
            capture_output=True, text=True, timeout=5
        )
        result["agent_version"] = (ver.stdout + ver.stderr).strip()
    except FileNotFoundError:
        result["agent_version"] = "binary not found"
    except Exception as e:
        result["agent_version_error"] = str(e)

    return jsonify(result), 200


def _burn_cpu(duration_seconds):
    end = time.time() + duration_seconds
    x = 0
    while time.time() < end:
        x += 1


@app.route("/spike-cpu")
def spike_cpu():
    """Pegs all CPU cores for a fixed window to simulate a real CPU-pressure incident."""
    duration = 20
    workers = multiprocessing.cpu_count()
    log.warning("spike-cpu hit: starting %d worker processes for %ss", workers, duration)

    procs = [multiprocessing.Process(target=_burn_cpu, args=(duration,)) for _ in range(workers)]
    for p in procs:
        p.start()
    for p in procs:
        p.join()

    log.warning("spike-cpu hit: all workers finished")
    return jsonify(status="cpu_spiked", duration_seconds=duration, workers=workers)


@app.route("/crash")
def crash():
    """Kills the process outright. systemd (Restart=always) brings it back."""
    log.error("crash endpoint hit: process exiting now")
    os._exit(1)


if __name__ == "__main__":
    port = int(os.environ.get("APP_PORT", 5000))
    app.run(host="0.0.0.0", port=port)