#!/bin/bash
# devbox-oomadj: keep every process in the box an equal OOM-kill candidate.
#
# Railway starts `railway ssh` sessions (the dashboard's "SSH" command) with
# oom_score_adj -950. When something run from such a session fills the
# container's memory, the kernel spares it and kills everything else first:
# ttyd, nginx, the respawn loops and entrypoint.sh. The container exits, Railway
# records the deployment as `crashed` + `oom_killed`, and each exit spends one
# of the deployment's ten ON_FAILURE restarts; the eleventh leaves it CRASHED.
# Measured 2026-10-18 at 0.5 GB (Free plan): one 800 MB Python allocation per
# exit, ten exits, deployment CRASHED. The same allocation from the browser
# terminal (oom_score_adj 0) only killed Python.
#
# Raising a process's oom_score_adj needs no capability (lowering does, and the
# container lacks it), so this loop resets any negative value above -1000 to 0
# four times a second. The kernel then kills the largest process, which is the
# one that ran out of memory, and the box keeps running.
set -u
exec {tick}<> <(:)   # read -t on an idle pipe: a sleep without a fork
while :; do
  for f in /proc/[0-9]*/oom_score_adj; do
    read -r adj < "$f" 2>/dev/null || continue
    if (( adj < 0 && adj > -1000 )); then
      { echo 0 > "$f"; } 2>/dev/null
    fi
  done
  read -t 0.25 -u "$tick" || true
done
