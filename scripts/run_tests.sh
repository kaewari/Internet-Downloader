#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
cd "$DIR"

echo "=========================================================="
echo "  Internet Downloader for macOS - Comprehensive Verification"
echo "=========================================================="

echo "==> 1. Building all SPM products (Core, Native Host, Desktop App)..."
swift build

echo "==> 2. Running all Unit & Integration Tests..."
swift test --verbose

echo "==> 3. Verifying Browser Extension Structure..."
if [ ! -f "Extension/manifest.json" ]; then
    echo "ERROR: Missing Extension/manifest.json"
    exit 1
fi
if [ ! -f "Extension/background.js" ]; then
    echo "ERROR: Missing Extension/background.js"
    exit 1
fi
if [ ! -f "Extension/content.js" ]; then
    echo "ERROR: Missing Extension/content.js"
    exit 1
fi
if [ ! -f "Extension/icons/icon128.png" ]; then
    echo "ERROR: Missing Extension icons"
    exit 1
fi

echo "=========================================================="
echo "  ALL VERIFICATION CHECKS PASSED SUCCESSFULLY (100%)"
echo "=========================================================="
