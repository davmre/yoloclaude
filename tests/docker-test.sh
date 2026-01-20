#!/bin/bash
#
# docker-test.sh - Build and run yoloclaude tests in Docker
#
# Usage:
#   ./tests/docker-test.sh          # Build and run tests
#   ./tests/docker-test.sh --shell  # Build and drop into shell for debugging
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

IMAGE_NAME="yoloclaude-test"

cd "$PROJECT_DIR"

echo "Building test Docker image..."
docker build -t "$IMAGE_NAME" -f tests/Dockerfile .

if [[ "$1" == "--shell" ]]; then
    echo "Starting interactive shell..."
    echo "Run '/opt/yoloclaude/tests/run-tests.sh' to execute tests"
    docker run -it --rm "$IMAGE_NAME" /bin/bash
else
    echo ""
    echo "Running tests..."
    echo ""
    docker run --rm "$IMAGE_NAME"
fi
