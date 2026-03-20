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
# (files created between this log's start and the next log's start)
ALL_LOGS="$LOGFILE"
session_start=$(stat -c%Y "$LOGFILE" 2>/dev/null)
for f in $(ls -1t logs/zmk_*.log 2>/dev/null); do
    if [ "$f" != "$LOGFILE" ]; then
        f_time=$(stat -c%Y "$f" 2>/dev/null)
        # Include files modified after this log was created (rotated siblings)
        if [ "$f_time" -ge "$session_start" ] 2>/dev/null; then
            ALL_LOGS="$ALL_LOGS $f"
        fi
    fi
done

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
first_wall=$(echo "$first_line" | grep -oP '^\[\K[0-9-]+ [0-9:.]+')
last_wall=$(echo "$last_line" | grep -oP '^\[\K[0-9-]+ [0-9:.]+')
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
    wall=$(echo "$line" | grep -oP '^\d+:\[\K[0-9-]+ [0-9:.]+')
    uptime=$(echo "$line" | grep -oP '\[\d{2}:\d{2}:\d{2}\.\d{3},\d{3}\]')
    msg=$(echo "$line" | grep -oP '<dbg> zmk: \K.*')
    echo "  [$wall] $uptime $msg"
done
echo ""

echo "--- Disconnect reasons ---"
grep "reason" $ALL_LOGS | sed 's/\x1b\[[0-9;]*m//g' | while IFS= read -r line; do
    wall=$(echo "$line" | grep -oP '^\[\K[0-9-]+ [0-9:.]+')
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
    wall=$(echo "$line" | grep -oP '^\[\K[0-9-]+ [0-9:.]+')
    msg=$(echo "$line" | grep -oP '<dbg> zmk: \K.*')
    echo "  [$wall] $msg"
done
echo ""

# --- Errors and warnings ---
echo "========================================"
echo "ERRORS AND WARNINGS"
echo "========================================"
echo ""
err_count=$(grep -ciE '<err>|<wrn>|fault|panic|assert|overflow|hard.?fault|bus.?fault|mem.?fault|usage.?fault|stack.?overflow' $ALL_LOGS)
echo "Total error/warning lines: $err_count"
if [ "$err_count" -gt 0 ]; then
    echo ""
    grep -iE '<err>|<wrn>|fault|panic|assert|overflow|hard.?fault|bus.?fault|mem.?fault|usage.?fault|stack.?overflow' $ALL_LOGS | sed 's/\x1b\[[0-9;]*m//g' | head -50
fi
echo ""

# --- Time gaps (potential stalls) ---
echo "========================================"
echo "TIME GAPS (>2s between log lines)"
echo "========================================"
echo ""
echo "(Gaps in wall-clock time may indicate MCU stalls or USB buffer delays)"
echo ""
prev_ts=""
prev_epoch=0
gap_count=0
while IFS= read -r line; do
    ts=$(echo "$line" | grep -oP '^\[\K[0-9-]+ [0-9:.]+')
    if [ -n "$ts" ]; then
        epoch=$(date -d "$ts" +%s 2>/dev/null)
        if [ -n "$epoch" ] && [ "$prev_epoch" -gt 0 ] 2>/dev/null; then
            gap=$((epoch - prev_epoch))
            if [ "$gap" -gt 2 ] && [ "$gap" -lt 86400 ]; then
                echo "  ${gap}s gap: $prev_ts -> $ts"
                gap_count=$((gap_count + 1))
            fi
        fi
        prev_ts="$ts"
        prev_epoch="$epoch"
    fi
done < <(sed -n '1~100p' $ALL_LOGS)
if [ "$gap_count" -eq 0 ]; then
    echo "  None detected"
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
    wall=$(echo "$line" | grep -oP '^\[\K[0-9-]+ [0-9:.]+')
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
    wall=$(echo "$line" | grep -oP '^\[\K[0-9-]+ [0-9:.]+')
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
    wall=$(echo "$line" | grep -oP '^\[\K[0-9-]+ [0-9:.]+')
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
    wall=$(echo "$line" | grep -oP '^\[\K[0-9-]+ [0-9:.]+')
    uptime=$(echo "$line" | grep -oP '\[\d{2}:\d{2}:\d{2}\.\d{3},\d{3}\]')
    echo "  [$wall] $uptime"
done
echo ""

# --- Final context (last 30 lines) ---
echo "========================================"
echo "CRASH CONTEXT (last 30 log lines)"
echo "========================================"
echo ""
last_log=$(echo $ALL_LOGS | tr ' ' '\n' | tail -1)
tail -30 "$last_log" | sed 's/\x1b\[[0-9;]*m//g'
echo ""

echo "========================================"
echo "END OF REPORT"
echo "========================================"
} > "$REPORT"

echo "Report written to: $REPORT"
