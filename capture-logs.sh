#!/bin/bash
# ZMK USB Logging Capture Script
# Usage: ./capture-logs.sh

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOGFILE="logs/zmk_${TIMESTAMP}.log"
DEVICE="/dev/ttyACM0"
MAX_LOG_SIZE_MB=10  # Rotate log when it reaches this size

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Trap Ctrl+C and cleanup
cleanup() {
    echo -e "\n${YELLOW}Stopping log capture...${NC}"
    # Kill all background jobs (including tio/cat from process substitution)
    jobs -p | xargs -r kill 2>/dev/null || true
    # Also try killing the entire process group
    kill -- -$$ 2>/dev/null || true
    exit 0
}
trap cleanup SIGINT SIGTERM

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

# Function to get file size in MB
get_file_size_mb() {
    if [ -f "$1" ]; then
        local size_bytes=$(stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null)
        echo $((size_bytes / 1048576))
    else
        echo 0
    fi
}

# Function to rotate log file
rotate_log() {
    local current_log="$1"
    local new_timestamp=$(date +%Y%m%d_%H%M%S)
    local new_log="logs/zmk_${new_timestamp}.log"

    echo ""
    echo -e "${BLUE}↻ Rotating log file (reached ${MAX_LOG_SIZE_MB}MB limit)${NC}"
    echo -e "${BLUE}  New file: $new_log${NC}"
    echo ""

    LOGFILE="$new_log"
}

# Display capture info
echo "Log file: $LOGFILE"
echo "Device: $DEVICE"
echo "Max log size: ${MAX_LOG_SIZE_MB}MB (will auto-rotate)"
echo ""
echo -e "${GREEN}Starting log capture...${NC}"
echo "Press Ctrl+C to stop"
echo "---"
echo ""

# Capture logs with appropriate tool
# Using process substitution to avoid subshell and make trap work properly
if command -v tio &> /dev/null; then
    # tio with timestamping, auto-reconnect, and log rotation
    while IFS= read -r line; do
        # Check log size and rotate if needed
        current_size=$(get_file_size_mb "$LOGFILE")
        if [ "$current_size" -ge "$MAX_LOG_SIZE_MB" ]; then
            rotate_log "$LOGFILE"
        fi

        echo "[$(date '+%Y-%m-%d %H:%M:%S.%3N')] $line" | tee -a "$LOGFILE"
    done < <(tio -t $DEVICE 2>&1)
else
    # Fallback to cat with timestamping and log rotation
    echo -e "${YELLOW}Using 'cat' fallback (timestamps may be less accurate)${NC}"
    while IFS= read -r line; do
        # Check log size and rotate if needed
        current_size=$(get_file_size_mb "$LOGFILE")
        if [ "$current_size" -ge "$MAX_LOG_SIZE_MB" ]; then
            rotate_log "$LOGFILE"
        fi
capture-logs.sh
        echo "[$(date '+%Y-%m-%d %H:%M:%S.%3N')] $line" | tee -a "$LOGFILE"
    done < <(cat $DEVICE 2>&1)
fi
