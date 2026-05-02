# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This repository benchmarks Podman vs Docker by running the same container workload on both runtimes and comparing performance metrics such as startup time, execution time, and resource usage.

## Scripts

| Script | Runtime | Description |
|---|---|---|
| `bench_podman.sh` | Podman | Runs a target container using `podman run` and records timing/resource metrics |
| `bench_docker.sh` | Docker | Runs the same container using `docker run` and records identical metrics |

Both scripts output results to `results/` in a common format so they can be compared directly.

## Running the Benchmarks

```bash
# Run Podman benchmark
bash bench_podman.sh

# Run Docker benchmark
bash bench_docker.sh

# Run both back-to-back and diff results
bash bench_podman.sh && bash bench_docker.sh
diff results/podman.txt results/docker.txt
```

## Architecture

- Each script is standalone and independently runnable
- Both scripts measure the same metrics using the same method (e.g., `time`, `/usr/bin/time -v`, or `perf`) so results are directly comparable
- Raw results are written to `results/podman.txt` and `results/docker.txt`
- The container image and workload used must be identical between both scripts — parameterize via a shared variable or config if the image changes

## Conventions

- Keep the two benchmark scripts structurally identical — same flags, same image, same iteration count — so differences reflect only the runtime
- Results files are gitignored; only scripts are committed
- Required system dependencies: `podman`, `docker`, `bash`
