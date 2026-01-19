#!/bin/bash
# Connect Dactyl Right Bluetooth Keyboard
# Interactive script to connect, disconnect, or remove the keyboard

set -euo pipefail

DEVICE_MAC="E0:65:35:C3:FD:33"
DEVICE_NAME="Dactyl Right"
MAX_RETRIES=3
MAX_SCAN_ATTEMPTS=20  # Wait up to 2 minutes for keyboard to appear
SCAN_WAIT_TIME=6      # Seconds between scan attempts
MAX_PAIR_ATTEMPTS=10  # Keep trying to pair until it works

echo "=== Dactyl Right Bluetooth Connection Script ==="
echo ""

# Check if device exists and current connection status
device_exists=false
device_connected=false
if bluetoothctl info "$DEVICE_MAC" 2>/dev/null | grep -q "Device"; then
    device_exists=true
    if bluetoothctl info "$DEVICE_MAC" 2>/dev/null | grep -q "Connected: yes"; then
        device_connected=true
    fi
fi

# Show current status
if [[ "$device_exists" == "true" ]]; then
    echo "Current status:"
    bluetoothctl info "$DEVICE_MAC" 2>/dev/null | grep -E "(Name|Paired|Bonded|Trusted|Connected|Battery)" || true
    echo ""
fi

# Ask user what they want to do
echo "What would you like to do?"
if [[ "$device_connected" == "true" ]]; then
    echo "  1) Keep connected (do nothing)"
    echo "  2) Disconnect"
    echo "  3) Remove device and re-pair fresh"
    echo "  4) Exit"
    echo ""
    read -p "Choose an option (1-4): " -n 1 -r choice
    echo ""
    echo ""

    case $choice in
        1)
            echo "Keyboard is already connected. Exiting."
            exit 0
            ;;
        2)
            echo "Disconnecting $DEVICE_NAME..."
            if bluetoothctl disconnect "$DEVICE_MAC"; then
                echo "✓ Disconnected from $DEVICE_NAME"
            else
                echo "Device was not connected or disconnect failed"
            fi
            exit 0
            ;;
        3)
            echo "Removing $DEVICE_NAME..."
            bluetoothctl disconnect "$DEVICE_MAC" 2>/dev/null || true
            if bluetoothctl remove "$DEVICE_MAC"; then
                echo "✓ Removed $DEVICE_NAME"
                echo ""
                echo "Will now attempt to re-pair..."
                sleep 2
            else
                echo "Remove failed"
                exit 1
            fi
            ;;
        4)
            echo "Exiting."
            exit 0
            ;;
        *)
            echo "Invalid choice. Exiting."
            exit 1
            ;;
    esac
elif [[ "$device_exists" == "true" ]]; then
    echo "  1) Connect to keyboard"
    echo "  2) Remove device and re-pair fresh"
    echo "  3) Exit"
    echo ""
    read -p "Choose an option (1-3): " -n 1 -r choice
    echo ""
    echo ""

    case $choice in
        1)
            echo "Will attempt to connect..."
            ;;
        2)
            echo "Removing $DEVICE_NAME..."
            if bluetoothctl remove "$DEVICE_MAC"; then
                echo "✓ Removed $DEVICE_NAME"
                echo ""
                echo "Will now attempt to pair fresh..."
                sleep 2
            else
                echo "Remove failed"
                exit 1
            fi
            ;;
        3)
            echo "Exiting."
            exit 0
            ;;
        *)
            echo "Invalid choice. Exiting."
            exit 1
            ;;
    esac
else
    echo "  1) Search for keyboard and pair"
    echo "  2) Exit"
    echo ""
    read -p "Choose an option (1-2): " -n 1 -r choice
    echo ""
    echo ""

    case $choice in
        1)
            echo "Will search for keyboard..."
            ;;
        2)
            echo "Exiting."
            exit 0
            ;;
        *)
            echo "Invalid choice. Exiting."
            exit 1
            ;;
    esac
fi

echo "Scanning for $DEVICE_NAME..."
echo "Make sure the keyboard is in pairing mode if this is a fresh pairing."
echo "Will wait up to $((MAX_SCAN_ATTEMPTS * SCAN_WAIT_TIME)) seconds for keyboard to appear..."

# Wait for device to appear
device_found=false
for scan_attempt in $(seq 1 $MAX_SCAN_ATTEMPTS); do
    # Scan for devices (using timeout to run scan in background properly)
    timeout 5s bluetoothctl --timeout 5 scan on &>/dev/null || true

    # Check if device is found
    if bluetoothctl devices | grep -q "$DEVICE_MAC"; then
        device_found=true
        echo "Found $DEVICE_NAME!"
        break
    fi

    if [[ $scan_attempt -lt $MAX_SCAN_ATTEMPTS ]]; then
        echo "Scan attempt $scan_attempt/$MAX_SCAN_ATTEMPTS: Device not found, waiting ${SCAN_WAIT_TIME}s..."
        sleep $SCAN_WAIT_TIME
    fi
done

if [[ "$device_found" == "false" ]]; then
    echo ""
    echo "Device not found after $MAX_SCAN_ATTEMPTS attempts. Please ensure:"
    echo "  1. Keyboard is powered on"
    echo "  2. Keyboard is in pairing mode (if not previously paired)"
    echo "  3. Keyboard is within range"
    echo "  4. Battery is not depleted"
    exit 1
fi

# Aggressive pairing loop - keep trying until we get proper bonding
echo "Ensuring proper pairing and bonding..."
for pair_attempt in $(seq 1 $MAX_PAIR_ATTEMPTS); do
    # Check current pairing/bonding/trust state
    info_output=$(bluetoothctl info "$DEVICE_MAC" 2>/dev/null)
    is_paired=$(echo "$info_output" | grep -q "Paired: yes" && echo "yes" || echo "no")
    is_bonded=$(echo "$info_output" | grep -q "Bonded: yes" && echo "yes" || echo "no")
    is_trusted=$(echo "$info_output" | grep -q "Trusted: yes" && echo "yes" || echo "no")

    echo "Attempt $pair_attempt/$MAX_PAIR_ATTEMPTS - Current state: Paired=$is_paired, Bonded=$is_bonded, Trusted=$is_trusted"

    # If everything is good, we're done
    if [[ "$is_paired" == "yes" && "$is_bonded" == "yes" && "$is_trusted" == "yes" ]]; then
        echo "✓ Device is properly paired, bonded, and trusted!"
        break
    fi

    # If in corrupted state (not paired/bonded), remove and start fresh
    if [[ "$is_paired" == "no" || "$is_bonded" == "no" ]]; then
        echo "Detected corrupted pairing state, removing device..."
        bluetoothctl remove "$DEVICE_MAC" 2>/dev/null || true
        sleep 2

        # Re-scan to find device
        echo "Re-scanning for device..."
        timeout 5s bluetoothctl --timeout 5 scan on &>/dev/null || true
        sleep 1
    fi

    # Trust the device
    if [[ "$is_trusted" != "yes" ]]; then
        echo "Trusting device..."
        bluetoothctl trust "$DEVICE_MAC" 2>/dev/null || true
        sleep 1
    fi

    # Attempt pairing
    echo "Attempting to pair..."
    pair_output=$(bluetoothctl pair "$DEVICE_MAC" 2>&1) || true

    if echo "$pair_output" | grep -q "Pairing successful"; then
        echo "✓ Pairing successful!"
        sleep 2
        # Verify bonding happened
        if bluetoothctl info "$DEVICE_MAC" 2>/dev/null | grep -q "Bonded: yes"; then
            echo "✓ Bonding confirmed!"
            break
        else
            echo "⚠ Paired but not bonded, retrying..."
        fi
    elif echo "$pair_output" | grep -q "AlreadyExists"; then
        echo "Device reports AlreadyExists but is not properly paired - this is a corrupted state"
        # Will be removed on next iteration
    else
        echo "Pairing attempt failed: $pair_output"
    fi

    if [[ $pair_attempt -lt $MAX_PAIR_ATTEMPTS ]]; then
        echo "Waiting 3 seconds before retry..."
        sleep 3
    fi
done

# Final verification
info_output=$(bluetoothctl info "$DEVICE_MAC" 2>/dev/null)
if ! echo "$info_output" | grep -q "Paired: yes"; then
    echo ""
    echo "❌ FAILED: Could not establish proper pairing after $MAX_PAIR_ATTEMPTS attempts"
    echo "The keyboard is likely in a corrupted BLE state."
    echo ""
    echo "REQUIRED ACTIONS:"
    echo "  1. Flash settings_reset firmware to BOTH keyboard halves"
    echo "  2. OR disconnect battery from both halves for 10 seconds"
    echo "  3. Then run this script again"
    exit 1
fi

# Connect with retry
echo ""
echo "Connecting to $DEVICE_NAME..."
for attempt in $(seq 1 $MAX_RETRIES); do
    if bluetoothctl connect "$DEVICE_MAC" 2>/dev/null; then
        sleep 1

        # Verify final state
        info_output=$(bluetoothctl info "$DEVICE_MAC" 2>/dev/null)
        is_paired=$(echo "$info_output" | grep -q "Paired: yes" && echo "yes" || echo "no")
        is_bonded=$(echo "$info_output" | grep -q "Bonded: yes" && echo "yes" || echo "no")
        is_trusted=$(echo "$info_output" | grep -q "Trusted: yes" && echo "yes" || echo "no")
        is_connected=$(echo "$info_output" | grep -q "Connected: yes" && echo "yes" || echo "no")

        echo ""
        echo "=== Connection Status ==="
        echo "$info_output" | grep -E "(Name|Paired|Bonded|Trusted|Connected|Battery)" || true
        echo ""

        # Verify all states are correct
        if [[ "$is_paired" == "yes" && "$is_bonded" == "yes" && "$is_trusted" == "yes" && "$is_connected" == "yes" ]]; then
            echo "✅ SUCCESS: Keyboard is fully paired, bonded, trusted, and connected!"
            echo ""
            echo "You can now use your keyboard normally."
            exit 0
        else
            echo "❌ WARNING: Connected but missing required states:"
            echo "   Paired: $is_paired (need: yes)"
            echo "   Bonded: $is_bonded (need: yes)"
            echo "   Trusted: $is_trusted (need: yes)"
            echo "   Connected: $is_connected (need: yes)"
            echo ""
            echo "This indicates a corrupted BLE stack state on the keyboard."
            echo "REQUIRED ACTIONS:"
            echo "  1. Flash settings_reset firmware to BOTH keyboard halves"
            echo "  2. OR disconnect battery from both halves for 10 seconds"
            echo "  3. Then run this script again"
            exit 1
        fi
    fi
    if [[ $attempt -lt $MAX_RETRIES ]]; then
        echo "Connection attempt $attempt failed, retrying in 2 seconds..."
        sleep 2
    fi
done

echo "Connection failed after $MAX_RETRIES attempts. Try the following:"
echo "  1. Restart bluetooth: sudo systemctl restart bluetooth"
echo "  2. Remove and re-pair: bluetoothctl remove $DEVICE_MAC"
echo "  3. Put keyboard in pairing mode and run this script again"
exit 1
