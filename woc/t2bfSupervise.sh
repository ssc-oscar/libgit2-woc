#!/bin/bash
# t2bfSupervise.sh  -- RUN ON da5. Produce t2bf to da5:/fast; **isaac drains (pulls + deletes) the
# completed t2bf.<sec>.gz from the SSD** (like t2ct). We do NOT copy to da8. Under SSD disk pressure
# we STOP creating and wait for isaac to free space, then resume -- a foreground-runner loop:
#   run one t2bfHost.sh PASS (job-pool; the driver's own 2T floor guard DISKSKIPs sections when tight,
#   then the pass exits) -> wait for free space -> repeat until 128 built.
set -u
SRC=/fast/All.blobsGen/t2bf
PAR=${PAR:-8}                # concurrency: 8*285G=2.3T concurrent in-flight < the driver's 3.7T floor -> no overflow
HI_KB=${HI_KB:-4700000000}   # ~4.5T: only START a pass with at least this free (above floor+in-flight buffer)
while true; do
  d=$(ls "$SRC"/t2bf.*.done 2>/dev/null | wc -l)
  if [ "$d" -ge 128 ]; then echo "=== t2bf ALL 128 DONE $(date -u) ==="; break; fi
  fk=$(df -P /fast | awk 'NR==2{print $4+0}')
  if [ "$fk" -lt "$HI_KB" ]; then
    echo "=== SSD pressure: $d/128 built, only $(df -h /fast|awk 'NR==2{print $4}') free -> PAUSE creation, wait for isaac to drain $(date -u) ==="
    sleep 180; continue
  fi
  echo "=== RUN PASS: $d/128 built, $(df -h /fast|awk 'NR==2{print $4}') free $(date -u) ==="
  bash /da5_fast/bin/t2bfHost.sh "$PAR" >> /tmp/t2bf_build.log 2>&1   # foreground pass; exits at floor
  echo "=== pass ended: $(ls "$SRC"/t2bf.*.done 2>/dev/null|wc -l)/128 built $(date -u) ==="
  sleep 15
done
