#!/bin/bash
# Trigger report generation from a running capture-logs session.
# Double-click from a file manager or run from another terminal.
# capture-logs.sh handles all file operations.

PID_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logs/capture.pid"

if [ ! -f "$PID_FILE" ]; then
    echo "No capture session running"
    exit 1
fi

PID=$(cat "$PID_FILE")

if kill -USR1 "$PID" 2>/dev/null; then
    echo "Report requested — see logs/report_*.txt"
else
    echo "Capture process not running"
    exit 1
fi
