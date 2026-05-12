#!/usr/bin/env bash
# Link or register a Signal number with the Hermes signal-cli REST API gateway.
# Optionally configure Hermes Signal adapter in one shot.
#
# Path A — QR link (link as secondary device on an existing number):
#   link-device.sh --phone +15551234567 [--name mybot] [--invites +15559876543,+15551112222]
#
# Path B — SMS register (register a dedicated bot number directly):
#   link-device.sh --register --phone +15551234567 [--captcha 'signalcaptcha://...'] [--voice] [--invites ...]
#
# Flags:
#   --phone     Phone number in E.164 format (required).
#               Path A: the number being linked (your personal number).
#               Path B: the bot's dedicated number.
#   --name      Device name shown in Signal → Linked Devices (default: Hermes-<hostname>).
#               Only used in Path A.
#   --register  Switch to SMS/voice registration mode (Path B).
#   --captcha   Captcha token (Signal sometimes requires one at
#               https://signalcaptchas.org/registration/generate.html).
#   --voice     Use voice call instead of SMS for verification code.
#   --invites   Additional phone numbers allowed to message the bot (comma-separated).
#
# After linking or registration, configures Hermes automatically.
set -euo pipefail

API_PORT="${CLOUDIFY_SIGNAL_PORT:-8080}"
API_URL="http://127.0.0.1:${API_PORT}"
DEVICE_NAME="Hermes-$(hostname)"
SIGNAL_PHONE=""
SIGNAL_INVITES=""
MODE="link"       # "link" or "register"
CAPTCHA_TOKEN=""
USE_VOICE=false

# --- Parse flags ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --phone)
            SIGNAL_PHONE="${2:-}"
            shift 2
            ;;
        --name)
            DEVICE_NAME="${2:-}"
            shift 2
            ;;
        --invites)
            SIGNAL_INVITES="${2:-}"
            shift 2
            ;;
        --register)
            MODE="register"
            shift
            ;;
        --captcha)
            CAPTCHA_TOKEN="${2:-}"
            shift 2
            ;;
        --voice)
            USE_VOICE=true
            shift
            ;;
        *)
            echo "Usage:"
            echo "  $0 --phone +15551234567 [--name mybot] [--invites +N1,+N2]"
            echo "  $0 --register --phone +15551234567 [--captcha TOKEN] [--voice] [--invites +N1,+N2]"
            exit 1
            ;;
    esac
done

if [[ -z "$SIGNAL_PHONE" ]]; then
    echo "Error: --phone is required."
    exit 1
fi

if [[ -n "$CAPTCHA_TOKEN" && "$MODE" != "register" ]]; then
    echo "Error: --captcha requires --register."
    exit 1
fi

if [[ "$USE_VOICE" == true && "$MODE" != "register" ]]; then
    echo "Error: --voice requires --register."
    exit 1
fi

# Build the allowed users list: owner + invites
if [[ -n "$SIGNAL_INVITES" ]]; then
    SIGNAL_ALLOWED_USERS="${SIGNAL_PHONE},${SIGNAL_INVITES}"
else
    SIGNAL_ALLOWED_USERS="${SIGNAL_PHONE}"
fi

# --- Check API is up ---
if ! curl -sf "${API_URL}/v1/about" >/dev/null 2>&1; then
    echo "Error: Signal API is not running."
    echo "Check: systemctl status hermes-signal-gateway"
    exit 1
fi

# --- Check if already registered/linked ---
ACCOUNTS=$(curl -sf "${API_URL}/v1/accounts" 2>/dev/null || echo "[]")
if [ "$ACCOUNTS" != "[]" ] && [ -n "$ACCOUNTS" ]; then
    echo "Already registered: ${ACCOUNTS}"
    echo "Configuring Hermes..."
    hermes config set SIGNAL_HTTP_URL "http://127.0.0.1:${API_PORT}"
    hermes config set SIGNAL_ACCOUNT "$SIGNAL_PHONE"
    hermes config set SIGNAL_ALLOWED_USERS "$SIGNAL_ALLOWED_USERS"
    echo "Done. Start the gateway: hermes gateway start"
    exit 0
fi

# =====================================================================
# Configure Hermes (shared helper)
# =====================================================================
configure_hermes() {
    echo ""
    echo "Configuring Hermes..."
    hermes config set SIGNAL_HTTP_URL "http://127.0.0.1:${API_PORT}"
    hermes config set SIGNAL_ACCOUNT "$SIGNAL_PHONE"
    hermes config set SIGNAL_ALLOWED_USERS "$SIGNAL_ALLOWED_USERS"
    echo ""
    echo "Done. Start the gateway:"
    echo "  hermes gateway start"
}

# =====================================================================
# Path A: QR code linking (existing behavior)
# =====================================================================
if [[ "$MODE" == "link" ]]; then
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
            configure_hermes
            break
        fi
        sleep 3
    done

    exit 0
fi

# =====================================================================
# Path B: SMS/voice registration (new)
# =====================================================================
echo "==================================================================="
echo "                SIGNAL REGISTRATION (DEDICATED NUMBER)             "
echo "==================================================================="
echo " Phone: ${SIGNAL_PHONE}"
echo ""
echo " WARNING: Registering a number with signal-cli will de-authenticate"
echo " the Signal mobile app for that number. Use a dedicated bot number,"
echo " NOT your personal number."
echo ""
echo " Signal will send a verification code to this number."
echo "==================================================================="

# --- Build registration request body ---
REG_BODY="{}"
if [[ -n "$CAPTCHA_TOKEN" ]]; then
    REG_BODY=$(echo "$REG_BODY" | jq --arg c "$CAPTCHA_TOKEN" '. + {captcha: $c}')
fi
if [[ "$USE_VOICE" == true ]]; then
    REG_BODY=$(echo "$REG_BODY" | jq '. + {use_voice: true}')
fi

# --- Send registration request ---
echo ""
echo "Requesting verification code..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -d "$REG_BODY" \
    "${API_URL}/v1/register/${SIGNAL_PHONE}")

if [[ "$HTTP_CODE" != "201" ]]; then
    echo "Error: Registration request failed (HTTP ${HTTP_CODE})."
    if [[ "$HTTP_CODE" == "400" ]]; then
        echo "Signal may require a captcha. Get one at:"
        echo "  https://signalcaptchas.org/registration/generate.html"
        echo "Then re-run with: --captcha 'signalcaptcha://...'"
    fi
    exit 1
fi

if [[ "$USE_VOICE" == true ]]; then
    echo "Verification code sent via voice call to ${SIGNAL_PHONE}."
else
    echo "Verification code sent via SMS to ${SIGNAL_PHONE}."
fi

# --- Prompt for verification code ---
echo ""
echo "Enter the verification code (e.g. 123-456):"
read -r VERIFY_CODE

if [[ -z "$VERIFY_CODE" ]]; then
    echo "Error: No verification code entered."
    exit 1
fi

# --- Verify the code ---
echo "Verifying..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    "${API_URL}/v1/register/${SIGNAL_PHONE}/verify/${VERIFY_CODE}")

if [[ "$HTTP_CODE" != "201" ]]; then
    echo "Error: Verification failed (HTTP ${HTTP_CODE})."
    echo "Check the code and try again. If the number has a registration lock PIN,"
    echo "you may need to use docker exec to verify with a PIN."
    exit 1
fi

echo ""
echo "Registration successful!"
echo "Account: ${SIGNAL_PHONE}"

# --- Restart the service so signal-cli picks up the new account ---
echo "Restarting signal-cli-rest-api..."
sudo systemctl restart hermes-signal-gateway

# Wait for API to come back up
echo -n "Waiting for API"
for _ in $(seq 1 30); do
    if curl -sf "${API_URL}/v1/about" >/dev/null 2>&1; then
        echo " ready."
        break
    fi
    echo -n "."
    sleep 2
done

if ! curl -sf "${API_URL}/v1/about" >/dev/null 2>&1; then
    echo ""
    echo "Warning: API did not come back after restart."
    echo "Check: systemctl status hermes-signal-gateway"
fi

configure_hermes
