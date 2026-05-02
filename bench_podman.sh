#!/usr/bin/env bash
set -euo pipefail

IMAGE="alpine:latest"
RUNS=10
RESULTS_DIR="results"
OUTPUT="$RESULTS_DIR/podman.txt"

if ! command -v podman &>/dev/null; then
    echo "Error: podman is not installed or not in PATH" >&2
    exit 1
fi

mkdir -p "$RESULTS_DIR"

echo "=== Podman Benchmark ==="
echo "Image:   $IMAGE"
echo "Runs:    $RUNS"
echo "Date:    $(date)"
echo "Version: $(podman --version)"
echo ""

# Pre-pull image so network latency is excluded from timing
echo "Pulling image..."
podman pull "$IMAGE" --quiet

echo ""
echo "--- Container Startup + CPU Workload ---"

times=()

{
    echo "=== Podman Benchmark ==="
    echo "Image:   $IMAGE"
    echo "Runs:    $RUNS"
    echo "Date:    $(date)"
    echo "Version: $(podman --version)"
    echo ""
    echo "--- Container Startup + CPU Workload ---"
} > "$OUTPUT"

for i in $(seq 1 "$RUNS"); do
    start=$(date +%s%N)
    podman run --rm "$IMAGE" sh -c 'for i in $(seq 1 1000); do echo $i; done > /dev/null'
    end=$(date +%s%N)
    elapsed_ms=$(( (end - start) / 1000000 ))
    times+=("$elapsed_ms")
    echo "Run $i: ${elapsed_ms} ms" | tee -a "$OUTPUT"
done

# Compute min / max / avg
total=0
min="${times[0]}"
max="${times[0]}"

for t in "${times[@]}"; do
    total=$(( total + t ))
    (( t < min )) && min=$t || true
    (( t > max )) && max=$t || true
done

avg=$(( total / RUNS ))

{
    echo ""
    echo "--- Summary ---"
    echo "Min:  ${min} ms"
    echo "Max:  ${max} ms"
    echo "Avg:  ${avg} ms"
} | tee -a "$OUTPUT"

echo ""
echo "Results saved to $OUTPUT"
