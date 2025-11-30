#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Load environment variables from .env if it exists
if [ -f "$PROJECT_DIR/.env" ]; then
    set -a
    source "$PROJECT_DIR/.env"
    set +a
fi

# Configuration - these MUST be set in .env or environment
if [ -z "$TEST_HOST" ]; then
    echo "Error: TEST_HOST not set. Please create a .env file (see .env.example)"
    exit 1
fi

if [ -z "$TEST_USER" ]; then
    echo "Error: TEST_USER not set. Please create a .env file (see .env.example)"
    exit 1
fi

cd "$PROJECT_DIR"

echo "========================================="
echo "Deploying cockpit-networkmanager-halos"
echo "========================================="

# Find the .deb package (in current directory)
DEB_FILE=$(ls -t cockpit-networkmanager-halos_*.deb 2>/dev/null | head -1)

if [ -z "$DEB_FILE" ]; then
    echo "Error: No .deb package found. Run build.sh first."
    exit 1
fi

echo "Package: $DEB_FILE"
echo "Target: $TEST_USER@$TEST_HOST"
echo ""

# Copy package to test device
echo "Copying package to test device..."
scp "$DEB_FILE" "$TEST_USER@$TEST_HOST:/tmp/"

DEB_FILENAME=$(basename "$DEB_FILE")

# Install package on test device
echo ""
echo "Installing package on test device..."
ssh "$TEST_USER@$TEST_HOST" "sudo dpkg -i /tmp/$DEB_FILENAME && sudo systemctl restart cockpit.socket || true"

echo ""
echo "========================================="
echo "Deployment complete!"
echo "========================================="
echo ""
echo "Access Cockpit at: https://$TEST_HOST:9090"
echo "Navigate to: Network > WiFi"
