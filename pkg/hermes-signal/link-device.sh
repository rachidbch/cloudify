#!/usr/bin/env bash
# Link a Signal phone to the Hermes signal-cli REST API gateway.
# Run this script after: cloudify install hermes-signal
# Then run: hermes gateway setup
set -euo pipefail

API_PORT="${CLOUDIFY_SIGNAL_PORT:-8080}"
API_URL="http://127.0.0.1:${API_PORT}"
DEVICE_NAME="HermesVPS"

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
        echo "Now run: hermes gateway setup"
        echo "  - Select 'Signal'"
        echo "  - Endpoint: http://127.0.0.1:${API_PORT}"
        echo "  - Enter your phone number (E.164 format, e.g. +1234567890)"
        echo "  - Set allowed users"
        break
    fi
    sleep 3
done
