# Local search speed test

See [the first local result](RESULTS.md) for measured times and limits.
See [memory probe results](PROBE_RESULTS.md) for binary search and worker-count
comparisons, and [probe instructions](PROBES.md) to run them.
See [real source-tree results](REAL_RESULTS.md) for the `beam_weaver` and `deps`
test, including repeated searches and file updates. [Run it with these instructions](REAL.md).
See [root-cause probes](DIAGNOSIS.md) for file-layout costs and the slow regex.

Compare a basic agent search on the same files:

- `bash_rg`: Start Bash with no profile, then run `rg` on local files.
- `shell_local`: Run the serial Elixir search through `Jido.Shell.Agent` and a
  mounted `Jido.VFS.Adapter.Local` filesystem.
- `shell_memory`: Run the same Elixir search through `Jido.Shell.Agent` and a
  mounted `Jido.VFS.Adapter.InMemory` filesystem.

The pinned Shell dependency has no built-in `grep` command. `support.exs`
provides a benchmark-only backend. It accepts `grep literal PATTERN` and
`grep regex PATTERN`. It does not change the dependency or its command registry.
This is a first implementation, with one search task and one file read at a
time. It does not represent the maximum possible BEAM search speed.

Run from this project root:

```sh
mise exec -- mix run bench/search/run.exs
mise exec -- mix run bench/search/run.exs --sizes small --runs 3
mise exec -- mix run bench/search/run.exs --runs 20 --output bench/search/results/run-20.json
```

`bench/search/mise.toml` records the experiment's tool versions. The commands
above use tools on the parent project's PATH. Check the recorded `rg` version
in each result when you compare runs.

The default run uses seven samples per query. It writes JSON with each sample,
median, p95, match count, setup times, and runtime versions. With seven samples,
p95 is the slowest sample. Use more samples to study time variation.

| Case | Bytes | Files |
|---|---:|---:|
| Small | 1 MiB | 64 |
| Medium | 16 MiB | 1,024 |
| Large | 128 MiB | 8,192 |

Each file has 16 KiB. Each directory has at most 64 files. File content is
repeatable ASCII source-like text. All files are written to disk first, then
read into memory. Each query includes directory traversal. There are six
queries: plain text and regular expressions, each with zero, rare, and frequent
matches. Rare means one matching line per file. Frequent means most lines.

Each result contains all matching lines, with a file name and line number.
There is no output cap. Frequent matches can use much more RAM than the input
files. Output collection is part of the measured time. Output sorting and
comparison are outside the measured time. Every sample must have the same
results as `rg`. The integration test also checks known answers, repeated
matches on one line, an empty line, a file with no final newline, and an invalid
regular expression.

Before measurement, each path runs to check results and warm the cache. The
order of the three paths is random for each repeat. Setup, fixture generation,
compilation, BEAM startup, and session startup are outside search time. Bash
and `rg` process startup are inside search time. This models repeated tool
calls from a running BEAM agent.
`rg` uses its default thread settings. The Elixir search uses one task.

These are warm-cache tests. They do not measure physical disk read speed or a
cold cache. Local files can be in the OS cache. The test does not clear that
cache. A memory win would apply to these tools and this workload; it would not
prove that memory storage alone caused the win. Compare `shell_local` with
`shell_memory` to study the storage path with the same search implementation.
The memory delta is total BEAM memory after load minus before load. It is an
approximate retained cost, not peak RAM or OS process RSS. Each case closes its
workspaces and removes its temporary disk files.

The Elixir regular expression engine and the default `rg` engine differ. These
queries use shared syntax. The test does not claim full grep compatibility.
The Shell backend collects one output binary. It does not test time to first
match, streaming, cancellation, concurrent agents, or ignored and binary files.
Those are possible next tests. File count and file size also need separate
experiments after this first run.

Run all integration examples through the integration runner:

```sh
mise exec -- mix test.integration
```

The integration alias starts each example file in a separate BEAM instance.
To run this experiment's file directly, use:

```sh
mise exec -- mix test test/examples/search_spike_test.exs --include integration
```
