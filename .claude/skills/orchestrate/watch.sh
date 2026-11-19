#!/bin/zsh
# Usage: watch.sh <orch-dir> <task-id> <pane-id>
# Run it as a Monitor (timeout_ms 1800000) once the worker says working. It blocks on
# `herdr agent wait` until the worker's turn ends, then prints one verdict and exits:
# DONE or QUESTION (with the file), IDLE (no report), BLOCKED, AGENT GONE, or
# STILL WORKING when the wait expires (re-arm).
orch=$1 task=$2 pane=$3
herdr agent wait $pane --until idle --until done --until blocked --until unknown --timeout 1740000 >/dev/null 2>&1
st=$(herdr agent get $pane 2>/dev/null | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["result"]["agent"]["agent_status"])
except Exception: print("")')
case $st in
  "") echo "AGENT GONE" ;;
  working) echo "STILL WORKING" ;;
  blocked) echo "BLOCKED" ;;
  *)
    if [[ -f $orch/$task.done ]]; then echo "DONE"; cat $orch/$task.done
    elif [[ -f $orch/$task.question ]]; then echo "QUESTION"; cat $orch/$task.question
    else echo "IDLE (no report) state=$st"; fi ;;
esac
