# First local run

Date: 2026-10-17. macOS on Apple ARM64, 10 BEAM schedulers, Elixir 1.20.4,
OTP 29, ripgrep 15.1.0. Seven samples per query. Times are medians in ms.

Memory search won five of six small queries. `rg` won every medium and large
query. Memory storage helped the serial BEAM search, but it did not make that
search faster than `rg` for the larger data sets.

| Size | Query | Bash + rg | Shell + local VFS | Shell + memory VFS |
|---|---|---:|---:|---:|
| small | literal_miss | 9.93 | 7.72 | 2.38 |
| small | literal_rare | 10.83 | 7.67 | 2.37 |
| small | literal_common | 10.94 | 11.01 | 5.61 |
| small | regex_miss | 9.25 | 13.65 | 8.72 |
| small | regex_rare | 10.08 | 13.22 | 7.71 |
| small | regex_common | 10.32 | 18.21 | 12.54 |
| medium | literal_miss | 19.86 | 114.69 | 36.54 |
| medium | literal_rare | 29.56 | 110.69 | 35.97 |
| medium | literal_common | 37.80 | 276.65 | 168.47 |
| medium | regex_miss | 19.83 | 233.57 | 144.03 |
| medium | regex_rare | 29.73 | 204.39 | 125.56 |
| medium | regex_common | 35.83 | 367.23 | 279.24 |
| large | literal_miss | 102.75 | 973.35 | 280.90 |
| large | literal_rare | 181.97 | 984.65 | 276.12 |
| large | literal_common | 316.66 | 2388.28 | 1652.41 |
| large | regex_miss | 101.78 | 1767.92 | 1128.95 |
| large | regex_rare | 174.75 | 1677.17 | 993.49 |
| large | regex_common | 223.15 | 3149.73 | 2521.34 |

| Size | Load disk files into memory, ms | Approximate BEAM memory increase, MiB |
|---|---:|---:|
| small | 7.47 | 1.12 |
| medium | 109.93 | 17.02 |
| large | 1718.33 | 131.61 |

Every measured output matched `rg`, including paths, line numbers, and full
matching lines. All 13 integration example files passed, including the new
search correctness test. Changed Elixir files passed the format check.

These are warm-cache, complete-output tests on generated text. They do not
measure physical disk read speed. The Shell search is a benchmark-only serial
Elixir backend because the pinned Shell version has no built-in grep command.
`rg` uses its default thread settings. Bash and rg startup are included;
BEAM startup and VFS loading are excluded. This result applies to these tools
and these inputs. It does not establish a general BEAM performance limit.

Raw samples and p95 values are in `results/latest.json`. That generated file is
ignored by Git and is replaced on the next default run. The table above keeps
the first result for comparison.

Next: test an output limit of 100 lines, then vary file count separately from
total bytes. After that, compare a faster BEAM implementation and a real source
tree. Keep the same result checks.
