# Search root-cause probes

Date: 2026-10-17. The diagnostic verified all 10,792 files against the manifest
from the real-tree run before measurement. Five samples per timed comparison.
The per-file regex profile is one serial pass. The OS cache is warm.

## File access and layout

The literal query has no matches. The joined file contains exactly the same
bytes as the tree, concatenated without separators. All search paths returned
zero matches, so file-name and line-number differences do not affect this case.

| Path | Median, ms |
|---|---:|
| Start Bash and run true | 3.61 |
| Bash + rg across 10,792 files | 186.62 |
| Bash + rg across one joined file | 30.74 |
| Resident BEAM, 8 workers | 22.71 |
| Bash + rg file enumeration only | 31.78 |

This supports file access and layout as a major cause of the difference.
Bash startup alone is small. The resident service already has paths and file
binaries, so searches avoid directory traversal and repeated file reads.
The single-file rg path may also use different thread or memory-map strategies.
These measurements are not an additive syscall breakdown and do not isolate
physical disk speed. The content is warm in the OS cache.

Earlier controlled probes separated improvements in our BEAM code. On the
128 MiB synthetic rare-literal query, the original memory VFS path took 267.88 ms;
reusing file binaries reduced it to 185.24 ms; binary matching reduced it to
75.24 ms; eight workers reduced it to 20.24 ms. Those are earlier-run medians.
The original VFS reads use Agent calls. The frozen view avoids those calls.
Bulk binary matching also avoids splitting and matching every line first.

## Slow start_link regex

Pattern: `[A-Za-z_]+\.start_link\(`. Every valid match must contain the
literal text `.start_link(`. A binary existence check can safely reject a file
that lacks that text before the regex engine runs.

- Files that need the regex check: 236.
- Files without the required literal: 10,556.
- Serial regex scan time: 3009.12 ms.
- Scan time in files without the required literal: 2948.31 ms (97.98%).

| Path | Median, ms |
|---|---:|
| Bash + rg | 193.24 |
| BEAM, 8 workers, original regex scan | 947.38 |
| BEAM, 8 workers, required-literal check then regex | 45.84 |

The required-literal check runs inside each worker batch and is included in
the measurement. Every output matched rg exactly on warmup and each timed run.
This diagnostic uses manifest path order for its file batches. The earlier
real-tree run used VFS traversal order. Its 618.60 ms baseline is therefore
not directly comparable with this run. The original and filtered diagnostic
paths use the same file order. The cause of the cross-run timing change was
not separately isolated.

The measurement identifies avoidable regex scanning as the dominant cost for
this pattern. It does not prove a specific internal regex-engine mechanism,
such as catastrophic backtracking. No engine profiler was used.

The slowest files in the serial scan were:

| File | Scan time, ms | Matches |
|---|---:|---:|
| `/deps/llm_db/priv/llm_db/snapshot.json` | 268.19 | 0 |
| `/deps/hologram/assets/node_modules/prettier/plugins/flow.mjs` | 69.66 | 0 |
| `/deps/hologram/assets/node_modules/prettier/plugins/flow.js` | 57.86 | 0 |
| `/priv/static/hologram/chunk-USQI3G7L.js.map` | 38.73 | 0 |
| `/priv/static/hologram/runtime-OMUZ63FI.js.map` | 37.53 | 0 |

The filter is specific to this pattern. General regex support needs a correct
method to derive required literals, or a fallback when none can be proved.
The diagnostic does not change the normal benchmark search path.

## Meaning for the agent harness

The evidence supports a resident search service attached to a fixed workspace
version. It can reuse file binaries, use bulk match operations, and search
bounded batches in parallel. A safe literal prefilter can remove expensive
regex work on irrelevant files. The initial load, full refresh cost, output
size, and pattern-specific behavior still matter.

Incremental file-view updates and safe pattern planning are the next useful
experiments. This result does not establish a general BEAM language advantage.

Run from the jido_workspace root after the real-tree test:

```sh
mix run bench/search/diagnose.exs
```

The script stops if source bytes differ from the saved real-test manifest.
It writes `results/diagnosis.json`, including raw samples and the top 15 files.
Temporary copies are removed after the run.
