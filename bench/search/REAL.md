# Real source-tree search

Run from the `jido_workspace` project root:

```sh
mise exec -- mix run bench/search/real.exs
mise exec -- mix run bench/search/real.exs --source ../beam_weaver --runs 5 --output bench/search/results/real-five.json
```

The runner copies the selected files to a new temporary directory. It includes
ignored and hidden files, including `deps`. It excludes `.git` directories,
the top-level `_build`, symlinks, files with null bytes, and invalid UTF-8.
Both tools search the same copy. The original source tree is not changed.
The JSON result records each selected path, byte count, and SHA-256 hash. VFS
contents must match those hashes before search starts. The copy is fixed during
timing. Its creation is not an atomic snapshot of a concurrently edited source
tree. The manifest identifies the bytes actually tested.

There are ten queries: an absent token, the project name, `GenServer.call`,
`handle_call`, `defmodule`, `TODO`, function definitions, callback alternatives,
error tuples, and `start_link` calls. Patterns are fixed before the run.
They use line-local regex syntax shared by the two implementations.

Each query runs in three output modes:

- Complete matching lines, with paths and line numbers.
- Matching file names only.
- At most five matching lines per file, equivalent to `rg --max-count 5`.

The last mode is not a global five-line limit. The BEAM implementation finds
match positions across each file before it extracts up to five lines. It limits
output but does not yet stop the match scan early. The file-name mode uses a
single existence check per file and does not construct matching lines.

All BEAM paths run through a Jido Shell session. The original serial VFS search
is included for complete-line output. The faster paths reuse a frozen file
list and search it in four or eight file-count batches. There is no byte-based
load balancing. The worker count is a maximum; a single large file can dominate
one worker. These paths use native BEAM functions and do not start OS commands.

Bash starts rg for each request. `--hidden --no-ignore` includes all files in the
copy. `--text --encoding=none` searches the same raw bytes as BEAM, including any
UTF-8 BOM. No binary detection or transcoding is needed after corpus selection.
The OS cache is warm. BEAM startup is excluded. Bash and rg process startup,
request handling, matching, and output collection are included. VFS loading and
file-view creation are recorded separately. Output comparison is outside the
timer. Each path runs once before timing. Each query has at least three samples,
with shuffled engine order. Full normalized results must match for each sample.
Only counts and timings are printed; source lines are not saved in reports.

The workload test measures three repetitions of 1, 10, and 100 complete-line
searches. One search uses the absent-token query. Ten searches use each query
once. One hundred searches repeat that sequence ten times. File-view preparation
is outside these measured search batches. The report adds it to show the total
cost of starting from local files. Batch outputs are checked by byte count;
the separate query tests check exact results for every query and engine.

The update test changes ten `.ex` files under 100 KB in the temporary copy. It
adds a unique marker, applies the same bytes to VFS, and builds a new full file
view. Disk writes, VFS writes, full refresh, and searches are timed separately.
The old frozen view must remain unchanged. The refreshed view and rg must find
the same ten lines. This tests a full rebuild, not incremental view maintenance.
It is one update event, so its write and refresh times are exploratory.

Raw results are saved to `results/real.json`, which is ignored by Git. The
manifest is local and includes file names and content hashes. Temporary files
and all benchmark sessions are removed after the run.
