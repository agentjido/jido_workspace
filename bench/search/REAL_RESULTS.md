# Real source-tree results

Date: 2026-10-17. Apple ARM64, 10 BEAM schedulers, Elixir 1.20.4, OTP 29,
ripgrep 15.1.0. Three samples per query and per batch. All values below are
medians unless stated otherwise.

The fixed corpus contains 10,792 UTF-8 text files and 135.05 MiB.
It includes ignored files, deps, and generated assets. It excludes .git, the
top-level _build, symlinks, files with null bytes, and invalid UTF-8. About
94 MiB is in deps and 37 MiB is in priv. This is a broad workspace search,
not a test limited to Elixir source files.

The eight-worker memory path beat Bash plus rg on nine of ten query patterns
in each of the three output modes. The start_link regex was slower in BEAM.
The original serial VFS search was slower than rg for all ten full-line queries.

## Repeated searches and setup

VFS loading took 1.449 s. File-view preparation took 0.368 s.
The combined initial cost was 1.818 s. The last column adds that one
measured cost to the search median; loading was not repeated for each sample.
BEAM startup and session startup are excluded. The benchmark copy cost is
excluded from both tools because it is shared test preparation.

| Searches | Bash + rg, s | BEAM 4 search only, s | BEAM 8 search only, s | BEAM 8 + initial setup, s |
|---:|---:|---:|---:|---:|
| 1 | 0.187 | 0.025 | 0.023 | 1.840 |
| 10 | 1.926 | 1.609 | 1.010 | 2.828 |
| 100 | 19.686 | 16.315 | 12.290 | 14.107 |

The one-search batch uses the absent token. The ten-search batch uses all ten
patterns once. The hundred-search batch repeats that sequence ten times.
The eight-worker hundred-search samples ranged from 9.810 to 13.669 s; rg
ranged from 19.364 to 20.539 s. Treat the exact ratio as exploratory.

## Complete matching lines

Times in milliseconds. Each result includes path, line number, and full line.

| Query | Matching lines | Bash + rg | Original BEAM | BEAM 4 | BEAM 8 |
|---|---:|---:|---:|---:|---:|
| absent | 0 | 199.01 | 447.67 | 21.35 | 19.75 |
| project_name | 1,340 | 191.80 | 523.47 | 39.71 | 35.94 |
| server_call | 360 | 194.68 | 544.74 | 28.70 | 28.14 |
| callback | 539 | 196.24 | 571.77 | 32.16 | 30.37 |
| module_definition | 3,357 | 205.91 | 586.60 | 39.85 | 34.54 |
| todo | 591 | 191.94 | 667.87 | 58.14 | 50.01 |
| function_definition | 43,184 | 211.07 | 1425.30 | 153.30 | 85.97 |
| callbacks | 1,118 | 194.30 | 1211.22 | 32.27 | 24.53 |
| error_tuple | 1,875 | 194.99 | 1223.90 | 27.70 | 25.84 |
| start_link | 422 | 194.91 | 3149.66 | 1117.73 | 618.60 |

## Matching file names

Times in milliseconds.

| Query | Result rows | Bash + rg | BEAM 4 | BEAM 8 |
|---|---:|---:|---:|---:|
| absent | 0 | 190.73 | 20.29 | 21.16 |
| project_name | 227 | 193.65 | 33.32 | 27.11 |
| server_call | 96 | 192.42 | 28.27 | 26.17 |
| callback | 102 | 193.83 | 31.31 | 29.96 |
| module_definition | 2,279 | 209.70 | 35.71 | 32.94 |
| todo | 305 | 189.22 | 48.07 | 39.12 |
| function_definition | 2,118 | 206.39 | 83.45 | 57.60 |
| callbacks | 156 | 195.66 | 30.26 | 24.85 |
| error_tuple | 484 | 194.91 | 24.65 | 21.03 |
| start_link | 236 | 190.75 | 1148.89 | 656.13 |

## At most five matching lines per file

Times in milliseconds.

| Query | Result rows | Bash + rg | BEAM 4 | BEAM 8 |
|---|---:|---:|---:|---:|
| absent | 0 | 183.46 | 28.51 | 29.37 |
| project_name | 730 | 184.11 | 39.32 | 35.79 |
| server_call | 262 | 185.08 | 29.36 | 27.94 |
| callback | 328 | 182.84 | 34.02 | 30.45 |
| module_definition | 2,942 | 198.61 | 43.02 | 42.57 |
| todo | 518 | 181.53 | 65.31 | 53.42 |
| function_definition | 8,807 | 200.77 | 118.12 | 91.78 |
| callbacks | 554 | 186.71 | 33.13 | 28.12 |
| error_tuple | 1,337 | 195.29 | 29.70 | 27.29 |
| start_link | 376 | 492.50 | 1168.52 | 662.88 |

## After ten file changes

Only the temporary copy and its memory VFS were changed. Ten small .ex files
received a unique marker. The old file view remained unchanged. A new full
view and rg returned the same ten matching lines.

- Disk writes: 5.034 ms.
- VFS writes: 0.724 ms.
- Full file-view refresh: 1007.956 ms.
- Search after refresh: rg 213.132 ms; BEAM 4 30.701 ms; BEAM 8 46.360 ms.

This is one update event. Write calls do not include a disk fsync. The refresh
cost makes a single search after this update slower with the current memory
strategy. Incremental file-view maintenance is a useful next experiment.

## Interpretation and checks

The result supports repeated searches over a resident file view. It does not
show that BEAM is a faster regex engine. The pattern `[A-Za-z_]+\.start_link\(`
took 618.60 ms with eight workers versus 194.91 ms with rg for complete output.
That cause has not been profiled. The choice of pattern matters.

Some individual rg samples were about 600 ms while other samples for the same
query were about 190–210 ms. Medians reduce that effect, but three samples do
not establish stable tail latency. The corpus is warm in the OS cache. No
physical disk-read comparison is claimed.

Both paths use the exact same copied bytes. All 30 query/output combinations
passed exact normalized result checks on warmup and each measured sample.
Batch tests check output byte counts after exact query checks. Three correctness
tests passed, including corpus selection, file-name output, line limits, empty
lines, anchors, zero-length regex matches, and frozen-view behavior.

The capped BEAM path still computes match positions across each file before
extracting up to five lines. It is not a global result limit. The regex probe
supports the line-local patterns used here; it is not a general grep replacement.

Manifest SHA-256: `f8ce3678535bd1dbe774e08c917082c5d6aba6e4676cf678f213526fbe0498c1`.

See [run instructions and measurement boundaries](REAL.md). Raw samples and
the complete file manifest are in `results/real.json` (ignored by Git).
