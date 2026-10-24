#!/bin/bash
# One-liner (run over SSH on the target box):
# curl -sSL https://raw.githubusercontent.com/ajpri/Austin/foginstall-improvements/foginstall.sh | bash
set -euo pipefail

# FOG imaging server install wrapper
# Usage: ./foginstall.sh [-y]   (-y is passed through for an unattended FOG install)

if ! command -v apt >/dev/null 2>&1; then
    echo "Error: this script needs a Debian/Ubuntu system (apt not found)." >&2
    exit 1
fi

echo "Requesting superuser permission..."
sudo -v

echo "Updating package lists and installing git..."
sudo apt update
sudo apt install -y git

echo "Cloning FOG Project..."
sudo git clone https://github.com/FOGProject/fogproject.git /opt/fogproject

echo "Running the FOG installer..."
cd /opt/fogproject/bin
sudo ./installfog.sh "$@"

echo "Done."
