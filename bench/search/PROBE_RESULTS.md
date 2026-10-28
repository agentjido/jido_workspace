# Memory probe results

Date: 2026-10-17. Apple ARM64, 10 BEAM schedulers, Elixir 1.20.4, OTP 29,
Bash 3.2.57, ripgrep 15.1.0. All times are median milliseconds.

Binary search and parallel workers improved sparse searches. Frequent matches
still favored rg. All paths returned the same full lines, paths, and line
numbers as rg. The correctness tests passed for all four worker counts.

The frozen file list removes repeated VFS reads. It must be rebuilt after
changes. The table includes a fresh-list path to show that cost.

## No matches and rare matches

Five samples per path. Rare means one matching line per file.

| Size | Query | rg | Original VFS | Frozen lines, 1 | Binary, 1 | Binary, 2 | Binary, 4 | Binary, 8 | Fresh list + binary, 4 |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| medium | literal_miss | 20.09 | 35.59 | 23.67 | 9.19 | 5.64 | 5.09 | 4.39 | 18.03 |
| medium | literal_rare | 30.01 | 36.38 | 24.57 | 8.96 | 5.66 | 5.03 | 4.50 | 18.27 |
| medium | regex_miss | 20.68 | 140.70 | 133.17 | 21.71 | 11.86 | 7.87 | 6.11 | 21.32 |
| medium | regex_rare | 30.38 | 128.21 | 109.69 | 2.94 | 2.25 | 1.57 | 1.78 | 15.93 |
| large | literal_miss | 102.31 | 270.61 | 182.69 | 75.98 | 42.55 | 27.29 | 21.34 | 143.60 |
| large | literal_rare | 178.25 | 267.88 | 185.24 | 75.24 | 43.51 | 27.27 | 20.24 | 146.78 |
| large | regex_miss | 192.85 | 1157.17 | 1085.85 | 189.47 | 99.45 | 54.52 | 40.46 | 178.13 |
| large | regex_rare | 191.26 | 996.05 | 940.09 | 25.92 | 19.67 | 15.26 | 11.57 | 136.86 |

Frozen-list preparation took 14.14 ms for medium, 130.32 ms for large.
These preparation times are excluded from the frozen-list columns. They are
included in every fresh-list search.

For the large rare plain text query, removing VFS reads changed 267.88 ms to
185.24 ms. Binary matching reduced that to 75.24 ms. Eight workers reduced it
to 20.24 ms. Bash plus rg took 178.25 ms. The fresh-list four-worker path took
146.78 ms.

The large regex-miss rg samples ranged from 101.28 to 328.44 ms. Its 192.85 ms
median is variable. The frozen eight-worker path ranged from 34.54 to 51.56 ms.
Do not treat the exact ratio as stable.

## Frequent matches

16 MiB, three samples per path. Most lines match. This is a separate run.

| Query | rg | Original VFS | Frozen lines, 1 | Binary, 1 | Binary, 2 | Binary, 4 | Binary, 8 | Fresh list + binary, 4 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| literal_common | 34.85 | 165.71 | 185.56 | 290.27 | 174.91 | 87.31 | 56.50 | 97.64 |
| regex_common | 35.98 | 273.73 | 301.42 | 479.59 | 242.61 | 125.66 | 67.39 | 144.99 |

The serial binary method was slower than the original search for frequent
matches. Parallel workers recovered much of that cost, but rg remained faster.
The probe builds a match-position list and complete output for every matching
line. This path needs further work for large results.

## Next step

Keep the frozen file view per version. Use bounded batches, starting with four
or eight workers. Test an agent output limit next. Then test a real source tree
with uneven file sizes and frequent updates. Do not choose one algorithm for
all queries from these generated fixtures alone.

The regex probe uses whole-file matching and supports the line-local patterns
in this experiment. It is not a general grep replacement. See [probe details](PROBES.md).
Raw samples are in `results/probes-sparse.json` and `results/probes-dense.json`.
The generated JSON files are ignored by Git. The original benchmark is unchanged
except for an optional search-function hook used by these probes.
