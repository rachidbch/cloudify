#!/usr/bin/env bash
# Link a Signal phone to the Hermes signal-cli REST API gateway.
# Optionally configure Hermes Signal adapter in one shot.
#
# Usage:
#   link-device.sh [--phone +1234567890] [--users +1234567890,+0987654321]
#
# With --phone and --users: configures Hermes automatically after linking.
# Without flags: prints instructions to run 'hermes gateway setup' manually.
set -euo pipefail

API_PORT="${CLOUDIFY_SIGNAL_PORT:-8080}"
API_URL="http://127.0.0.1:${API_PORT}"
DEVICE_NAME="HermesVPS"
SIGNAL_PHONE=""
SIGNAL_USERS=""

# --- Parse flags ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --phone)
            SIGNAL_PHONE="${2:-}"
            shift 2
            ;;
        --users)
            SIGNAL_USERS="${2:-}"
            shift 2
            ;;
        *)
            echo "Usage: $0 [--phone +1234567890] [--users +1234567890,+0987654321]"
            exit 1
            ;;
    esac
done

if [[ -n "$SIGNAL_PHONE" && -z "$SIGNAL_USERS" ]] || [[ -z "$SIGNAL_PHONE" && -n "$SIGNAL_USERS" ]]; then
    echo "Error: --phone and --users must be used together (or both omitted for manual setup)."
    exit 1
fi

# --- Check API is up ---
if ! curl -sf "${API_URL}/v1/about" >/dev/null 2>&1; then
    echo "Error: Signal API is not running."
    echo "Check: systemctl status hermes-signal-gateway"
    exit 1
fi

# --- Check if already linked ---
ACCOUNTS=$(curl -sf "${API_URL}/v1/accounts" 2>/dev/null || echo "[]")
if [ "$ACCOUNTS" != "[]" ] && [ -n "$ACCOUNTS" ]; then
    echo "Already linked: ${ACCOUNTS}"
    if [[ -n "$SIGNAL_PHONE" ]]; then
        echo "Configuring Hermes..."
        hermes config set SIGNAL_HTTP_URL "http://127.0.0.1:${API_PORT}"
        hermes config set SIGNAL_ACCOUNT "$SIGNAL_PHONE"
        hermes config set SIGNAL_ALLOWED_USERS "$SIGNAL_USERS"
        echo "Done. Start the gateway: hermes gateway start"
    fi
    exit 0
fi

# --- Fetch pairing URI ---
echo "Fetching pairing code..."
URI=$(curl -sf "${API_URL}/v1/qrcodelink?device_name=${DEVICE_NAME}" | jq -r '.uri')

if [ -z "$URI" ] || [ "$URI" == "null" ]; then
    echo "Error: Could not fetch pairing URI from the API."
    exit 1
fi

# --- Display QR code ---
clear
echo "==================================================================="
echo "                  SIGNAL DEVICE LINKING REQUIRED                   "
echo "==================================================================="
echo " Maximize your terminal now (wrapped QR codes won't scan)."
echo ""
echo " 1. Open Signal on your phone."
echo " 2. Settings > Linked Devices > Link New Device."
echo " 3. Scan the QR code below:"
echo "==================================================================="
echo ""
qrencode -t ANSIUTF8 "$URI"
echo ""
echo "==================================================================="
echo " Waiting for scan... (Ctrl+C to cancel)"

# --- Poll for completion ---
while true; do
    CHECK=$(curl -sf "${API_URL}/v1/accounts" 2>/dev/null || echo "[]")
    if [ "$CHECK" != "[]" ] && [ -n "$CHECK" ]; then
        echo ""
        echo "Device linked successfully!"
        echo "Account: ${CHECK}"
        echo ""

        if [[ -n "$SIGNAL_PHONE" ]]; then
            echo "Configuring Hermes..."
            hermes config set SIGNAL_HTTP_URL "http://127.0.0.1:${API_PORT}"
            hermes config set SIGNAL_ACCOUNT "$SIGNAL_PHONE"
            hermes config set SIGNAL_ALLOWED_USERS "$SIGNAL_USERS"
            echo ""
            echo "Done. Start the gateway:"
            echo "  hermes gateway start"
        else
            echo "Now configure Hermes:"
            echo "  hermes gateway setup"
            echo "  - Select 'Signal'"
            echo "  - Endpoint: http://127.0.0.1:${API_PORT}"
            echo "  - Enter your phone number (E.164 format, e.g. +1234567890)"
            echo "  - Set allowed users"
            echo ""
            echo "Or use the one-liner for next time:"
            echo "  $0 --phone +1234567890 --users +1234567890"
        fi
        break
    fi
    sleep 3
done
