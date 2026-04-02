#!/bin/bash
# ZMK USB Logging Capture Script
# Usage: ./capture-logs.sh

DEVICE="/dev/ttyACM0"
LOGFILE=""
USB_LOG=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="logs/capture.pid"
CHILD_PID=""
USB_MONITOR_PID=""

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Stop current script/tio child and strip ANSI from its log
stop_child() {
    if [ -n "$CHILD_PID" ] && kill -0 "$CHILD_PID" 2>/dev/null; then
        kill "$CHILD_PID" 2>/dev/null
        wait "$CHILD_PID" 2>/dev/null
    fi
    # Kill any tio still holding the device (script doesn't always forward signals)
    fuser -k "$DEVICE" 2>/dev/null
    sleep 0.5
    # Strip ANSI escape codes and script header/footer now that script is done writing
    if [ -f "$LOGFILE" ]; then
        sed -i 's/\x1b\[[0-9;]*m//g; s/\r//g' "$LOGFILE"
        sed -i '/^Script started on/d; /^Script done on/d' "$LOGFILE"
    fi
}

# Monitor USB connection status and kernel events for the device.
# Writes timestamped events to a sidecar log alongside the serial capture.
start_usb_monitor() {
    # Find the USB bus path for our device (e.g. "1-1.3")
    local usb_path
    usb_path=$(udevadm info "$DEVICE" 2>/dev/null | grep -oP 'usb\d+/\K[0-9.-]+(?=/)' | head -1)
    if [ -z "$usb_path" ]; then
        echo -e "${YELLOW}Could not determine USB bus path — USB monitoring disabled${NC}"
        return
    fi

    USB_LOG="${LOGFILE%.log}_usb.log"
    echo "[$(date '+%H:%M:%S')] USB monitor started for $DEVICE (bus $usb_path)" > "$USB_LOG"
    echo "[$(date '+%H:%M:%S')] USB device: $(lsusb -d 1d50:615e 2>/dev/null)" >> "$USB_LOG"

    (
        # Stream kernel USB events for this device
        journalctl -k -f --no-pager -g "$usb_path" 2>/dev/null | while IFS= read -r line; do
            echo "[$(date '+%H:%M:%S')] KERNEL: $line" >> "$USB_LOG"
            # Also print to terminal for visibility
            echo -e "${RED}[USB] $line${NC}"
        done
    ) &
    USB_MONITOR_PID=$!

    # Periodic device health check (every 60s)
    (
        while true; do
            sleep 60
            if [ -e "$DEVICE" ]; then
                # Check if device is still enumerated
                if lsusb -d 1d50:615e >/dev/null 2>&1; then
                    echo "[$(date '+%H:%M:%S')] POLL: device present" >> "$USB_LOG"
                else
                    echo "[$(date '+%H:%M:%S')] POLL: DEVICE MISSING from lsusb!" >> "$USB_LOG"
                    echo -e "${RED}[USB] Device disappeared from lsusb!${NC}"
                fi
            else
                echo "[$(date '+%H:%M:%S')] POLL: $DEVICE node gone!" >> "$USB_LOG"
                echo -e "${RED}[USB] $DEVICE no longer exists!${NC}"
            fi
        done
    ) &
    USB_POLL_PID=$!
}

stop_usb_monitor() {
    [ -n "$USB_MONITOR_PID" ] && kill "$USB_MONITOR_PID" 2>/dev/null
    [ -n "$USB_POLL_PID" ] && kill "$USB_POLL_PID" 2>/dev/null
    # Strip ANSI from USB log too
    [ -f "$USB_LOG" ] && sed -i 's/\x1b\[[0-9;]*m//g; s/\r//g' "$USB_LOG"
}

# Start a new capture child with a fresh log file
start_child() {
    LOGFILE="logs/zmk_$(date +%Y%m%d_%H%M%S).log"
    if command -v tio &> /dev/null; then
        script -q "$LOGFILE" -c "tio -t $DEVICE" &
        CHILD_PID=$!
    else
        script -q "$LOGFILE" -c "cat $DEVICE" &
        CHILD_PID=$!
    fi
    start_usb_monitor
    echo -e "${GREEN}Log file: $LOGFILE${NC}"
}

# Generate report on current log without stopping capture
generate_report() {
    if [ -f "$LOGFILE" ] && [ -s "$LOGFILE" ]; then
        echo -e "\n${BLUE}Generating analysis report...${NC}"
        local report="logs/report_$(date +%Y%m%d_%H%M%S).txt"
        "$SCRIPT_DIR/analyze-log.sh" "$LOGFILE" "$report"
        echo -e "${GREEN}Report: $report${NC}"
    fi
}

# SIGUSR1: generate report on current log, then start fresh log
generate_report_and_rotate() {
    stop_usb_monitor
    stop_child
    generate_report
    start_child
}
trap generate_report_and_rotate USR1

# Ctrl+C / SIGTERM: request stop. The wait loop checks this flag.
STOP_REQUESTED=0
trap 'STOP_REQUESTED=1' INT TERM

# Cleanup on exit: stop child, generate final report
cleanup() {
    echo -e "\n${YELLOW}Stopping log capture...${NC}"
    stop_usb_monitor
    stop_child

    if [ -f "$LOGFILE" ] && [ -s "$LOGFILE" ]; then
        echo -e "${BLUE}Generating final report...${NC}"
        local report="logs/report_$(date +%Y%m%d_%H%M%S).txt"
        "$SCRIPT_DIR/analyze-log.sh" "$LOGFILE" "$report"
        echo -e "${GREEN}Report: $report${NC}"
    fi

    rm -f "$PID_FILE"
}
trap cleanup EXIT

echo "=== ZMK USB Logging Capture ==="
echo ""

# Create logs directory if it doesn't exist
mkdir -p logs

# Check for tio and offer to install if missing
if ! command -v tio &> /dev/null; then
    echo -e "${YELLOW}⚠ 'tio' is not installed${NC}"
    echo ""
    echo "'tio' is a modern serial device tool with better features than cat."
    echo "It provides:"
    echo "  - Proper terminal handling"
    echo "  - Auto-reconnect on disconnect"
    echo "  - Built-in timestamping"
    echo "  - Color output"
    echo ""
    read -p "Would you like to install tio? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Installing tio (requires sudo)..."
        sudo apt-get update -qq && sudo apt-get install -y tio
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ tio installed successfully${NC}"
            echo ""
        else
            echo -e "${RED}✗ Failed to install tio${NC}"
            echo "Continuing with 'cat' fallback..."
            echo ""
        fi
    else
        echo "Continuing with 'cat' fallback..."
        echo ""
    fi
fi

# Check if device exists
if [ ! -e "$DEVICE" ]; then
    echo -e "${RED}Error: $DEVICE not found${NC}"
    echo ""
    echo "Troubleshooting:"
    echo "1. Is the keyboard (right half) connected via USB?"
    echo "2. Did you flash the logging firmware (dactyl_right_logging)?"
    echo "3. Check for other serial devices: ls -la /dev/ttyACM*"
    exit 1
fi

echo -e "${GREEN}✓ Found device: $DEVICE${NC}"
echo ""
echo -e "${YELLOW}⚠ IMPORTANT: Make sure keyboard output is set to BLE, not USB${NC}"
echo -e "${YELLOW}  Press the &out OUT_BLE key combo (OS_FnNumbers layer) if needed.${NC}"
echo -e "${YELLOW}  This ensures keyboard data flows over BT while logs stream over USB.${NC}"
echo -e "${YELLOW}  The setting persists across reboots - you only need to set it once.${NC}"

# Check if we have permission to access the device
if [ ! -r "$DEVICE" ] || [ ! -w "$DEVICE" ]; then
    echo -e "${YELLOW}⚠ No permission to access $DEVICE${NC}"
    echo ""
    echo "Options:"
    echo "1. Add your user to the 'dialout' group (recommended, permanent):"
    echo "   sudo usermod -a -G dialout $USER"
    echo "   Then log out and log back in"
    echo ""
    echo "2. Use sudo for this session (temporary):"
    echo "   sudo chmod 666 $DEVICE"
    echo ""
    read -p "Would you like to add yourself to the dialout group? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        sudo usermod -a -G dialout $USER
        echo -e "${GREEN}✓ Added to dialout group${NC}"
        echo ""
        echo -e "${YELLOW}⚠ You must log out and log back in for this to take effect${NC}"
        echo ""
        read -p "Use sudo for this session? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            sudo chmod 666 $DEVICE
            echo -e "${GREEN}✓ Device permissions updated for this session${NC}"
        else
            echo "Please log out and log back in, then run this script again."
            exit 0
        fi
    else
        read -p "Use sudo for this session? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            sudo chmod 666 $DEVICE
            echo -e "${GREEN}✓ Device permissions updated for this session${NC}"
        else
            echo "Cannot continue without device access. Exiting."
            exit 1
        fi
    fi
    echo ""
fi

# Clean all previous logs and reports for a fresh session
rm -f logs/zmk_*.log logs/zmk_*_usb.log logs/report_*.txt

# Display capture info
echo "Device: $DEVICE"
echo ""

echo -e "${GREEN}Starting log capture...${NC}"
echo "Press Ctrl+C to stop and generate report"
echo "Run ./generate-report.sh from another terminal to rotate log and generate report"
echo "---"
echo ""

# Write PID file for generate-report.sh
echo $$ > "$PID_FILE"

# Start capture: `script` gives tio a real PTY (tio exits if stdout is a pipe).
# Runs in background; `wait` is signal-interruptible unlike `read`.
start_child

# Wait for Enter (or Ctrl+C / SIGTERM) to stop capture.
# `read -t 1` polls with a 1-second timeout to also check child liveness.
echo "Press Enter or Ctrl+C to stop and generate report"
echo ""
while kill -0 "$CHILD_PID" 2>/dev/null; do
    if read -t 1 -r input 2>/dev/null; then
        break
    fi
    [ "$STOP_REQUESTED" -eq 1 ] && break
done
