#!/bin/bash
set -e

echo "=== Replicating GitHub Actions CI Environment ==="
echo "OS: Ubuntu 24.04"
echo "Swift: 6.2"
echo ""

# Use the official Swift Docker image that matches GHA
docker run --rm -v "$(pwd):/workspace" -w /workspace \
  swift:6.2-noble \
  bash -c "
    echo '=== Swift Version ==='
    swift --version
    echo ''
    echo '=== Building ==='
    swift build
    echo ''
    echo '=== Running Tests ==='
    swift test
  "
