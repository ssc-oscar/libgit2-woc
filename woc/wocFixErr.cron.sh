#!/bin/bash
# Babysitter wrapper: timestamp + run the WoC err/blob monitor.
# Auto-fixes idle tag/tree SHA mismatches (data-present shards only) and
# reports oversized-blob offenders. Invoked from cron under flock.
export HOME=/home/exouser
export PATH=/usr/local/bin:/usr/bin:/bin
echo "=== $(date '+%F %T') ==="
/usr/bin/python3 /home/exouser/bin/wocFixErr.py
# de-offend oversized blob shards (kill+relaunch stuck grabs / re-extract blobs)
/home/exouser/bin/deOffendWatch.sh
echo
