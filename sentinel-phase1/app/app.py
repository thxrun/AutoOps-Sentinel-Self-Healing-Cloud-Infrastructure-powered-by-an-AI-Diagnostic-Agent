import logging
import os
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

FILL_DIR = "/tmp/sentinel-fill"
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


@app.route("/spike-cpu")
def spike_cpu():
    """Busy-loops for a fixed window to simulate a CPU spike."""
    log.warning("spike-cpu hit: starting busy loop")
    end = time.time() + 15  # 15 second spike, self-terminating
    x = 0
    while time.time() < end:
        x += 1
    log.warning("spike-cpu hit: busy loop finished")
    return jsonify(status="cpu_spiked", duration_seconds=15)


@app.route("/crash")
def crash():
    """Kills the process outright. systemd (Restart=always) brings it back."""
    log.error("crash endpoint hit: process exiting now")
    os._exit(1)


if __name__ == "__main__":
    port = int(os.environ.get("APP_PORT", 5000))
    app.run(host="0.0.0.0", port=port)
