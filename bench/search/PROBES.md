# Memory search probes

Run from the `jido_workspace` project root:

```sh
mix run bench/search/probe.exs --runs 5 --output bench/search/results/probes-sparse.json
mix run bench/search/probe.exs --sizes medium --dense --runs 3 --output bench/search/results/probes-dense.json
```

The default sizes are 16 MiB and 128 MiB. Files and queries use the same
fixture as the first experiment. `--sizes small` selects 1 MiB. By default,
queries have no matches or one matching line per file. `--dense` adds queries
that match most lines. Each result contains all matching lines, paths, and line
numbers. No output limit is used.

| Path | Change under test |
|---|---|
| `bash_rg` | Bash starts `rg` on local files, with the default rg thread settings |
| `vfs_lines_1` | Original serial BEAM search through the memory VFS |
| `snapshot_lines_1` | Same line search on a frozen list of file binaries |
| `snapshot_offsets_1` | Search each file binary and extract matching lines |
| `snapshot_offsets_2` | Same binary search with two workers |
| `snapshot_offsets_4` | Same binary search with four workers |
| `snapshot_offsets_8` | Same binary search with eight workers |
| `fresh_offsets_4` | Read a new list from memory VFS on every search, then use four workers |

All BEAM paths run through `Jido.Shell.Agent` and the benchmark backend. They
use native BEAM functions. They do not start Bash or rg. Each parallel worker
gets a batch of files. Worker creation and output collection are timed. Workers
produce complete output binaries; the caller combines them. Binary search
compiles the pattern once per request. Plain text uses `:binary.matches/2`.
Regular expressions use `Regex.scan/3` on each file. Match positions determine
which lines to extract. Repeated matches on one line produce one output line.

The frozen list is made by reading every file from the mounted memory VFS.
Its preparation time is recorded separately. Repeated searches reuse that list.
It represents a fixed file version and must be rebuilt after changes. The
`fresh_offsets_4` path includes that preparation in every timed search.
All paths start with files already loaded in memory or a warm OS cache. Disk
fixture creation, VFS loading, and session startup are outside search time.

Whole-file regular expressions can differ from line-by-line grep. These probes
use line-local expressions with shared syntax. Multiline anchors are enabled
for the whole-file scan. Absolute anchors, lookaround across lines, and patterns
that consume newlines need separate work before this can be a general grep
tool. A match that contains a newline raises an error in this probe.

Every path runs once before measurement. Each measured output is compared with
rg outside the timer. Paths run in a shuffled order with a fixed seed. JSON
contains every sample, median, minimum, maximum, tool versions, and setup time.
Small sample counts support exploration; they do not establish stable tail
latency. These tests use equal-size generated files. Test a real source tree
and uneven file sizes before choosing a production worker count.

The integration test checks all worker counts against the original search. It
includes empty files, empty lines, line anchors, zero-length regex matches,
UTF-8 bytes, repeated matches, and a file without a final newline. It also
checks that the frozen view stays unchanged after a VFS write.
