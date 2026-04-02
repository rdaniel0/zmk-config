#!/bin/bash
# ZMK Log Analyzer - generates a structured report from a capture log
# Usage: ./analyze-log.sh <logfile> [report_file]

LOGFILE="${1}"
REPORT="${2:-logs/report.txt}"

if [ -z "$LOGFILE" ]; then
    # Default to most recent log
    LOGFILE=$(ls -1t logs/zmk_*.log 2>/dev/null | head -1)
    if [ -z "$LOGFILE" ]; then
        echo "No log files found"
        exit 1
    fi
fi

if [ ! -f "$LOGFILE" ]; then
    echo "Log file not found: $LOGFILE"
    exit 1
fi

# Also analyze any rotated logs from the same capture session
ALL_LOGS="$LOGFILE"
session_start=$(stat -c%Y "$LOGFILE" 2>/dev/null)
for f in $(ls -1t logs/zmk_*.log 2>/dev/null | grep -v '_usb\.log$'); do
    if [ "$f" != "$LOGFILE" ]; then
        f_time=$(stat -c%Y "$f" 2>/dev/null)
        # Include files modified after this log was created (rotated siblings)
        if [ "$f_time" -ge "$session_start" ] 2>/dev/null; then
            ALL_LOGS="$ALL_LOGS $f"
        fi
    fi
done

# Preprocess: strip ANSI codes, carriage returns, and script headers into a clean temp file
CLEAN_LOG=$(mktemp /tmp/zmk-analyze-XXXXXX.log)
cat $ALL_LOGS | sed 's/\x1b\[[0-9;]*m//g; s/\r//g; /^Script started on/d; /^Script done on/d' > "$CLEAN_LOG"
ALL_LOGS="$CLEAN_LOG"
trap 'rm -f "$CLEAN_LOG"' EXIT

{
echo "========================================"
echo "ZMK Log Analysis Report"
echo "========================================"
echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
echo "Log file(s): $ALL_LOGS"
echo "Total lines: $(cat $ALL_LOGS | wc -l)"
echo ""

# --- Session timing ---
echo "========================================"
echo "SESSION TIMING"
echo "========================================"
first_line=$(head -1 "$LOGFILE")
last_line=$(tail -1 "$(echo $ALL_LOGS | tr ' ' '\n' | tail -1)")
echo "First entry: $first_line" | head -c 200
echo ""
echo "Last entry:  $last_line" | head -c 200
echo ""

# Extract wall-clock timestamps (first bracket pair)
first_wall=$(echo "$first_line" | grep -oP '^\[\K[^\]]+')
last_wall=$(echo "$last_line" | grep -oP '^\[\K[^\]]+')
echo "Wall clock: $first_wall -> $last_wall"

# Extract ZMK uptime timestamps (third bracket pair: [HH:MM:SS.mmm,uuu])
first_uptime=$(echo "$first_line" | grep -oP '\[\d{2}:\d{2}:\d{2}\.\d{3},\d{3}\]' | head -1)
last_uptime=$(echo "$last_line" | grep -oP '\[\d{2}:\d{2}:\d{2}\.\d{3},\d{3}\]' | head -1)
echo "ZMK uptime: $first_uptime -> $last_uptime"

# Check for uptime resets (would indicate a reboot)
echo ""
echo "Uptime resets (reboots):"
prev_ms=0
reboot_count=0
while IFS= read -r ts; do
    h=${ts:1:2}; m=${ts:4:2}; s=${ts:7:2}; ms=${ts:10:3}
    curr_ms=$((10#$h*3600000 + 10#$m*60000 + 10#$s*1000 + 10#$ms))
    if [ "$curr_ms" -lt "$((prev_ms - 5000))" ] 2>/dev/null; then
        echo "  REBOOT detected: uptime went from ${prev_ms}ms to ${curr_ms}ms"
        reboot_count=$((reboot_count + 1))
    fi
    prev_ms=$curr_ms
done < <(grep -oP '\[\d{2}:\d{2}:\d{2}\.\d{3},\d{3}\]' $ALL_LOGS | sed -n '1~500p')
if [ "$reboot_count" -eq 0 ]; then
    echo "  None detected (continuous uptime)"
fi

echo ""

# --- BLE connection events ---
echo "========================================"
echo "BLE CONNECTION EVENTS"
echo "========================================"
echo ""
echo "--- Peripheral (split) connections ---"
grep -n "split_central_connected\|split_central_disconnected\|Initiating new connection\|release_peripheral_slot\|SUBSCRIBED\|UNSUBSCRIBED\|security_changed\|transport_status_changed" $ALL_LOGS | sed 's/\x1b\[[0-9;]*m//g' | while IFS= read -r line; do
    # Extract wall timestamp and the message
    wall=$(echo "$line" | grep -oP '^\d+:\[\K[^\]]+')
    uptime=$(echo "$line" | grep -oP '\[\d{2}:\d{2}:\d{2}\.\d{3},\d{3}\]')
    msg=$(echo "$line" | grep -oP '<dbg> zmk: \K.*')
    echo "  [$wall] $uptime $msg"
done
echo ""

echo "--- Disconnect reasons ---"
grep "reason" $ALL_LOGS | sed 's/\x1b\[[0-9;]*m//g' | while IFS= read -r line; do
    wall=$(echo "$line" | grep -oP '^\[\K[^\]]+')
    reason=$(echo "$line" | grep -oP 'reason \K\S+' | tr -d ')')
    echo "  [$wall] reason=$reason"
done
# Decode common reasons
echo ""
echo "  Reason reference: 0x08=supervision timeout, 0x13=remote terminated,"
echo "  0x16=local terminated, 0x22=instant passed, 0x3e=conn failed"
echo ""

# --- Host endpoint events ---
echo "========================================"
echo "HOST ENDPOINT EVENTS"
echo "========================================"
echo ""
echo "Output transport changes:"
grep "zmk_endpoint_set_preferred_transport\|Selected endpoint transport\|endpoint_changed" $ALL_LOGS | sed 's/\x1b\[[0-9;]*m//g' | while IFS= read -r line; do
    wall=$(echo "$line" | grep -oP '^\[\K[^\]]+')
    msg=$(echo "$line" | grep -oP '<dbg> zmk: \K.*')
    echo "  [$wall] $msg"
done
echo ""

# --- Errors and warnings ---
echo "========================================"
echo "ERRORS AND WARNINGS"
echo "========================================"
echo ""
err_count=$(grep -iE '<err>|<wrn>|fault|panic|assert|overflow|hard.?fault|bus.?fault|mem.?fault|usage.?fault|stack.?overflow' $ALL_LOGS | grep -cv 'DIAG:')
echo "Total error/warning lines: $err_count (excluding DIAG)"
if [ "$err_count" -gt 0 ]; then
    echo ""
    grep -iE '<err>|<wrn>|fault|panic|assert|overflow|hard.?fault|bus.?fault|mem.?fault|usage.?fault|stack.?overflow' $ALL_LOGS | grep -v 'DIAG:' | sed 's/\x1b\[[0-9;]*m//g' | head -50
fi
echo ""

# --- Peripheral notification stats ---
echo "========================================"
echo "PERIPHERAL (SPLIT BLE) STATS"
echo "========================================"
echo ""
notif_count=$(grep -c "split_central_notify_func: \[NOTIFICATION\]" $ALL_LOGS)
echo "Total peripheral notifications: $notif_count"
echo ""
echo "Last 5 peripheral notifications:"
grep "split_central_notify_func: \[NOTIFICATION\]" $ALL_LOGS | tail -5 | sed 's/\x1b\[[0-9;]*m//g' | while IFS= read -r line; do
    wall=$(echo "$line" | grep -oP '^\[\K[^\]]+')
    uptime=$(echo "$line" | grep -oP '\[\d{2}:\d{2}:\d{2}\.\d{3},\d{3}\]')
    echo "  [$wall] $uptime"
done
echo ""

# --- Stuck key detection ---
echo "========================================"
echo "STUCK KEY ANALYSIS"
echo "========================================"
echo ""
echo "Last 10 key press/release events:"
grep -E "on_keymap_binding_(pressed|released):" $ALL_LOGS | tail -10 | sed 's/\x1b\[[0-9;]*m//g' | while IFS= read -r line; do
    wall=$(echo "$line" | grep -oP '^\[\K[^\]]+')
    msg=$(echo "$line" | grep -oP '<dbg> zmk: \K.*')
    echo "  [$wall] $msg"
done
echo ""

# Track all keys that were pressed but not released at end of log
# by scanning the last 200 press/release events
echo "Keys held at end of log (pressed without release):"
declare -A held_keys
unreleased_count=0
while IFS= read -r line; do
    pos=$(echo "$line" | grep -oP 'position \K\d+')
    code=$(echo "$line" | grep -oP 'keycode \K0x[0-9a-fA-F]+')
    wall=$(echo "$line" | grep -oP '^\[\K[^\]]+')
    if echo "$line" | grep -q "binding_pressed"; then
        held_keys["$pos"]="keycode=$code at $wall"
    elif echo "$line" | grep -q "binding_released"; then
        unset held_keys["$pos"]
    fi
done < <(grep "on_keymap_binding_\(pressed\|released\):" $ALL_LOGS | tail -200)

for pos in "${!held_keys[@]}"; do
    echo "  *** STUCK: position=$pos ${held_keys[$pos]}"
    unreleased_count=$((unreleased_count + 1))
done
if [ "$unreleased_count" -eq 0 ]; then
    echo "  None - all keys properly released"
else
    echo ""
    echo "  $unreleased_count key(s) stuck. MCU likely froze mid-keypress."
fi
echo ""

# --- HID report stats ---
echo "========================================"
echo "HID REPORT STATS"
echo "========================================"
echo ""
report_count=$(grep -c "zmk_endpoint_send_report:" $ALL_LOGS)
echo "Total HID reports sent: $report_count"
echo ""
echo "Last 5 HID reports:"
grep "zmk_endpoint_send_report:" $ALL_LOGS | tail -5 | sed 's/\x1b\[[0-9;]*m//g' | while IFS= read -r line; do
    wall=$(echo "$line" | grep -oP '^\[\K[^\]]+')
    uptime=$(echo "$line" | grep -oP '\[\d{2}:\d{2}:\d{2}\.\d{3},\d{3}\]')
    echo "  [$wall] $uptime"
done
echo ""

# --- Thread stack usage (from CONFIG_THREAD_ANALYZER) ---
echo "========================================"
echo "THREAD STACK USAGE"
echo "========================================"
echo ""
# Single-pass awk: extracts first/last snapshots, peak usage, and growth per thread.
# Pre-process with sed to extract fields, then awk for aggregation.
stack_report=$(grep 'STACK: unused' $ALL_LOGS | sed -n 's/^\[\([^]]*\)\] *\(.*\) *: STACK: unused \([0-9]*\) usage \([0-9]*\) \/ \([0-9]*\) (\([0-9]*\).*/\1\t\2\t\3\t\4\t\5\t\6/p' | awk -F'\t' '
    {
        timestamp = $1; thread = $2; unused = $3; used = $4; total = $5; pct = $6
        gsub(/^ +| +$/, "", thread)

        if (thread == "" || total == "") next

        if (first_ts == "") first_ts = timestamp
        if (timestamp == first_ts) first_used[thread] = used

        if (used + 0 > peak[thread] + 0) peak[thread] = used

        last_ts = timestamp
        last_used[thread] = used
        last_total[thread] = total
        last_unused[thread] = unused
        last_pct[thread] = pct

        if (!(thread in order_map)) {
            order_map[thread] = 1
            order[++num_threads] = thread
        }
        snapshots[timestamp] = 1
    }
    END {
        snap_count = 0
        for (s in snapshots) snap_count++

        printf "Snapshots: %d over session\n", snap_count
        printf "First: %s  Last: %s\n\n", first_ts, last_ts

        fmt = "  %-28s %6s %6s %6s %5s %8s  %6s\n"
        printf fmt, "Thread", "Used", "Total", "Free", "Usage", "Growth", "Peak"
        printf fmt, "------", "----", "-----", "----", "-----", "------", "----"

        for (i = 1; i <= num_threads; i++) {
            t = order[i]
            growth = ""
            if (t in first_used && first_used[t] != last_used[t]) {
                delta = last_used[t] - first_used[t]
                if (delta > 0) growth = sprintf("+%d !", delta)
                else growth = sprintf("%d", delta)
            }
            marker = ""
            if (last_pct[t] + 0 >= 80) marker = " ***"
            peak_str = sprintf("%d", peak[t])
            if (peak[t] > last_used[t]) peak_str = peak_str " ^"
            printf "  %-28s %6d %6d %6d %4d%%  %6s  %5s%s\n", \
                t, last_used[t], last_total[t], last_unused[t], last_pct[t], \
                growth, peak_str, marker
        }
        printf "\n  *** = 80%%+ usage    ! = grew since start    ^ = peak was higher than final\n"
    }
')
if [ -n "$stack_report" ]; then
    echo "$stack_report"
else
    echo "  No thread analyzer data found (enable CONFIG_THREAD_ANALYZER)"
fi
echo ""

# --- USB connection status ---
USB_LOG_FILE="${LOGFILE%.log}_usb.log"
if [ -f "$USB_LOG_FILE" ]; then
    echo "========================================"
    echo "USB CONNECTION STATUS"
    echo "========================================"
    echo ""
    echo "USB monitor log: $USB_LOG_FILE"
    echo ""
    # Show kernel events (disconnect/reconnect/errors)
    kernel_events=$(grep 'KERNEL:' "$USB_LOG_FILE" 2>/dev/null)
    if [ -n "$kernel_events" ]; then
        echo "Kernel USB events:"
        echo "$kernel_events" | while IFS= read -r line; do
            echo "  $line"
        done
    else
        echo "  No kernel USB events during capture"
    fi
    echo ""
    # Show any anomalies from polling
    poll_issues=$(grep -v 'device present' "$USB_LOG_FILE" | grep 'POLL:' 2>/dev/null)
    if [ -n "$poll_issues" ]; then
        echo "USB anomalies detected:"
        echo "$poll_issues" | while IFS= read -r line; do
            echo "  $line"
        done
    fi
    echo ""
fi

# --- Final context (last 30 lines) ---
echo "========================================"
echo "CRASH CONTEXT (last 30 log lines)"
echo "========================================"
echo ""
tail -30 "$ALL_LOGS" | sed 's/\x1b\[[0-9;]*m//g'
echo ""

echo "========================================"
echo "END OF REPORT"
echo "========================================"
} > "$REPORT"

echo "Report written to: $REPORT"
