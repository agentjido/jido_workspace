# 01.05 Read and write large files

Write an enumerable of byte chunks and read a file by offset. The same
calls work on memory and Docker.

```elixir
alias Jido.Workspace

{:ok, workspace} = Workspace.open(profile: :memory)

try do
  :ok = Workspace.mkdir(workspace, "reports")
  chunks = File.stream!("input.bin", 65_536, [])
  :ok = Workspace.write_stream(workspace, "reports/input.bin", chunks)

  {:ok, bytes} = Workspace.read_chunk(workspace, "reports/input.bin", 0, 65_536)
  byte_size(bytes)
after
  :ok = Workspace.close(workspace)
end
```

[The example source](example.ex) copies a file within one workspace and
computes its SHA-256 checksum one chunk at a time. Advance the offset by
the number of bytes returned. An empty binary indicates end of file.
Each read uses the current file. For a checksum of one version, keep the
file stable while you read the chunks.

## Write and interruption

- Create the destination's parent directory first. Pass an enumerable of
  iodata. Each chunk can contain up to 1 MiB. Set
  `limits: %{write_stream_bytes: bytes}` in the profile to change the
  total limit from 64 MiB. The write returns `:transfer_limit` when a
  chunk or the total exceeds its limit.
- Reads can use the current files while the transfer runs. Other writes,
  directory scans, commands, and saves return `:busy`. The write publishes
  the new file when the source finishes and the caller requests commit.
- Source failure and caller exit before commit leave the destination in
  its previous state. A source exception returns `:stream_failed`.
  Closing the workspace discards an unfinished transfer. If the commit
  reply is lost, inspect the destination after recovery.
- Memory holds the staged file bytes in memory. Docker writes to a
  temporary file beside the destination and publishes it with a rename.
  If the native sandbox controller is killed during staging, the checkout
  keeps the previous file and can keep a `.jido-write-*` file. The host
  can inspect and clean up the checkout before releasing its reservation.

A successful write publishes the file in the live tree. Use `save/1`
for a snapshot. The snapshot store has its own size limit.

## Run the tests

```sh
mix test examples/01_working_files/01_05_read_and_write_large_files/example_test.exs --include integration
JIDO_SANDBOX_DOCKER=1 JIDO_SANDBOX_IMAGE=alpine:3.20 \
  mix test examples/01_working_files/01_05_read_and_write_large_files/example_test.exs --include integration --warnings-as-errors
```

The tests copy a binary file, compare its checksum, and check the large
file again after save and reopen. A barrier stops the producer after
the first chunk. Both providers preserve the previous file when the
producer exits. The Docker tests use a host checkout to check close,
Workspace controller loss, and loss of the sandbox process that owns
the temporary file. [Tests](example_test.exs)
