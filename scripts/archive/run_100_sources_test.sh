#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$( dirname "$DIR" )"
cd "$ROOT_DIR"

echo "=========================================================="
echo "  Running 100 Sources Comprehensive Verification Suite    "
echo "=========================================================="

mkdir -p test_downloads/images test_downloads/videos

swift run test-100-sources
