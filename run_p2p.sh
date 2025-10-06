#!/bin/bash

# Test script for Chord P2P implementation  
# Usage: ./run_optimized.sh <nodes> <requests>

NODES=${1:-10}
REQUESTS=${2:-5}

echo "===== Testing Chord P2P Network ====="
echo "Running with $NODES nodes, $REQUESTS requests each"

if [ "$NODES" -gt 2000 ]; then
    echo "WARNING: Large network - this might take a while!"
fi

echo "Starting simulation..."
gleam run $NODES $REQUESTS

echo "===== Done ====="
