#!/bin/bash

# Memory-Optimized Chord P2P Test Script
# Usage: ./run_optimized.sh <nodes> <requests>

NODES=${1:-10}
REQUESTS=${2:-5}

echo "===== Memory-Optimized Chord P2P Implementation ====="
echo "Testing with $NODES nodes and $REQUESTS requests per node"

if [ "$NODES" -gt 2000 ]; then
    echo "WARNING: Very large network - may take significant time"
fi

echo "Running simulation..."
gleam run -m project3_optimized $NODES $REQUESTS

echo "===== Test Complete ====="