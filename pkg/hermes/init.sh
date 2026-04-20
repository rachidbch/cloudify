#!/usr/bin/env bash
# hermes — Nous Research AI agent
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --skip-setup

echo ""
echo "Next step: Prepare your model API keys and setup hermes by running:"
echo "  cloudify hermes shell -i hermes setup"
