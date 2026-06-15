#!/usr/bin/env bash
# Adds the kind Ingress hostnames to /etc/hosts so you can open
# http://frontend.local and http://query.local in your browser.
# Run once after ./bootstrap.sh completes.
set -euo pipefail

HOSTS_LINE="127.0.0.1  frontend.local query.local"
HOSTS_FILE="/etc/hosts"

if grep -q "frontend.local" "$HOSTS_FILE" 2>/dev/null; then
  echo "Hosts already configured."
else
  echo "Adding '$HOSTS_LINE' to $HOSTS_FILE (requires sudo)"
  echo "$HOSTS_LINE" | sudo tee -a "$HOSTS_FILE" > /dev/null
  echo "Done."
fi
