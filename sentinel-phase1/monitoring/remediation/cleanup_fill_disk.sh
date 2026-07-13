#!/bin/bash
# Pre-approved auto-remediation for the disk-fill scenario. This is the ONLY
# script Executor Lambda is allowed to run automatically (action_type ==
# "auto_safe") — intentionally narrow scope, not a general "run anything"
# capability.
set -eu

TARGET="/var/sentinel-fill"

if [ -d "$TARGET" ]; then
  BEFORE=$(df --output=pcent / | tail -1 | tr -d ' ')
  rm -f "${TARGET}"/*.bin
  AFTER=$(df --output=pcent / | tail -1 | tr -d ' ')
  echo "Cleanup complete. Disk usage: ${BEFORE} -> ${AFTER}"
else
  echo "Nothing to clean up — ${TARGET} does not exist."
fi