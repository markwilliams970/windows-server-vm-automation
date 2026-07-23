#!/usr/bin/env bash
# Repeatedly capture QEMU framebuffer screenshots via QMP at a fixed interval -
# for watching a boot sequence unfold (UEFI prompts, boot menus, WinPE/Setup
# screens) without needing a VNC viewer window at all. Each still is a
# separate timestamped PNG; inspect them directly rather than a live stream.
#
# Usage: qmp-watch.sh <qmp-socket> <output-dir> [interval-seconds] [count]
set -euo pipefail

SOCK="${1:?usage: qmp-watch.sh <qmp-socket> <output-dir> [interval-seconds] [count]}"
OUTDIR="${2:?output dir required}"
INTERVAL="${3:-0.5}"
COUNT="${4:-40}"

mkdir -p "$OUTDIR"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for i in $(seq -w 1 "$COUNT"); do
  ts="$(date +%H%M%S.%3N)"
  out="$OUTDIR/shot-${i}-${ts}.png"
  if ! "$SCRIPT_DIR/qmp-screenshot.py" --socket "$SOCK" --out "$out"; then
    echo "capture $i failed, stopping" >&2
    break
  fi
  echo "$out"
  sleep "$INTERVAL"
done
