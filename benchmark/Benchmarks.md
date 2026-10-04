# Benchmarks

> **Important:** The tables below show **HISTORICAL** upstream-Blink results (v0.17.1 era). These are not Snap performance claims and were generated on a different machine with a different codebase.

## Methodology Caveats

- Old benchmark fires 1000 events/frame—faster tools receive more offered load
- Bandwidth numbers are modeled (60/observed-frames normalized), not observed traffic
- Identical repeated payloads favor compression unrealistically
- Server validates only the first message
- Loss values rounded to whole percent

**These tables must not be read as Snap performance claims.**

## Historical Results (Upstream Blink v0.17.1)

Last Updated: 2025-04-30 19:45:09 UTC

### Tool Versions
- `blink`: v0.17.1
- `zap`: v0.6.20
- `bytenet`: v0.4.3

### Computer Specs
- Processor: AMD Ryzen 9 7900X 12-Core Processor
- Memory #1: 17GB 4800
- Memory #2: 17GB 4800

### [Entities](https://github.com/81117105108108/Snap/blob/main/benchmark/src/shared/benches/Entities.luau)

| Tool (FPS) | Median | P0 | P80 | P90 | P95 | P100 | Loss (%) |
|------------|--------|----|-----|-----|-----|------|----------|
| roblox | 16.00 | 16.00 | 15.00 | 15.00 | 15.00 | 15.00 | 0% |
| blink | 42.00 | 45.00 | 42.00 | 42.00 | 42.00 | 42.00 | 0% |
| zap | 39.00 | 40.00 | 38.00 | 38.00 | 38.00 | 38.00 | 0% |
| bytenet | 32.00 | 34.00 | 32.00 | 32.00 | 32.00 | 31.00 | 0% |

| Tool (Kbps) | Median | P0 | P80 | P90 | P95 | P100 | Loss (%) |
|-------------|--------|----|-----|-----|-----|------|----------|
| roblox | 559364.31 | 559364.31 | 676715.68 | 676715.68 | 676715.68 | 784081.75 | 0% |
| blink | 41.81 | 26.30 | 42.40 | 42.48 | 42.48 | 42.62 | 0% |
| zap | 41.71 | 25.46 | 42.19 | 42.32 | 42.32 | 42.93 | 0% |
| bytenet | 41.64 | 22.84 | 42.36 | 42.82 | 42.82 | 43.24 | 0% |

### [Booleans](https://github.com/81117105108108/Snap/blob/main/benchmark/src/shared/benches/Booleans.luau)

| Tool (FPS) | Median | P0 | P80 | P90 | P95 | P100 | Loss (%) |
|------------|--------|----|-----|-----|-----|------|----------|
| roblox | 21.00 | 22.00 | 20.00 | 19.00 | 19.00 | 19.00 | 0% |
| blink | 97.00 | 98.00 | 97.00 | 96.00 | 96.00 | 96.00 | 0% |
| zap | 52.00 | 53.00 | 51.00 | 51.00 | 51.00 | 49.00 | 0% |
| bytenet | 35.00 | 37.00 | 35.00 | 35.00 | 35.00 | 34.00 | 0% |

| Tool (Kbps) | Median | P0 | P80 | P90 | P95 | P100 | Loss (%) |
|-------------|--------|----|-----|-----|-----|------|----------|
| roblox | 353107.13 | 196826.86 | 690747.68 | 842240.25 | 842240.25 | 1124176.38 | 0% |
| blink | 7.91 | 7.41 | 7.93 | 7.99 | 7.99 | 8.00 | 0% |
| zap | 8.10 | 5.75 | 8.17 | 8.22 | 8.22 | 8.27 | 0% |
| bytenet | 8.11 | 5.07 | 8.35 | 8.46 | 8.46 | 8.47 | 0% |

## Snap Compiler Benchmarks

To measure Snap's compile-time performance:

```bash
lune run benchmark/compile_bench
```

- 30 iterations + 3 warmup runs (report medians)
- Workloads: `test/Sources/Test.blink` + in-memory synthetic-60
- Heap via `collectgarbage` count (live-memory sample, not allocation total)

**Observed ranges (one machine, not guaranteed):**
- Total compile time: tens of ms
- Parse: single-digit ms
- Generate: ~25-30ms (includes mandatory guards)
- Lune startup floor: ~80ms

Generated output grew ~16% from mandatory guards.

## Regenerating Transport Benchmarks

To produce valid Snap transport benchmarks:

1. Use local Snap compiler (not upstream Blink)
2. Pin all SHAs
3. Use realistic varying payloads
4. Fix messages/second
5. Report actual bytes and calls
6. Report p50/p95/p99 percentiles
7. Include warmup + randomized order

**Warning:** `benchmark/download.luau` + `benchmark/build.bat` currently pull upstream `1Axen/Blink`. They must be repointed at local Snap builds before publishing new transport numbers.
