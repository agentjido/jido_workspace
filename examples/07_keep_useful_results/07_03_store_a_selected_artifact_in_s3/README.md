# 07.03 Store a selected artifact in S3

Read one approved file from a saved workspace and store it in an S3
bucket. The host keeps the snapshot reference for the whole tree. The
consumer uses the artifact digest to get only the approved file.

## Read the approved file

Save the candidate and record its approved JSON reference as shown in
[07.01](../07_01_save_a_scratch_tree_to_disk/README.md). Open the reference
with a read-only profile. A Docker review uses the same calls and store
ID as a memory review.

```elixir
alias Jido.Workspace

{:ok, review} = Workspace.open(profile: :review, from: Jason.decode!(approved_reference))

report =
  try do
    {:ok, bytes} = Workspace.read(review, "report.txt")
    bytes
  after
    :ok = Workspace.close(review)
  end
```

## Put and get the artifact

The host configures the S3 destination. Supply the provider settings and
credentials as `host_s3_config`. Keep them in the host application. Give
the host session `s3:PutObject` and `s3:GetObject` on
`arn:aws:s3:::BUCKET/workspace-results/sha256/*`. The adapter prefix
selects the key namespace. The object store policy enforces access.
[S3 adapter setup](../../../docs/vfs/README.md#s3-adapter)

```elixir
Code.require_file("examples/07_keep_useful_results/07_03_store_a_selected_artifact_in_s3/example.ex")
alias Jido.VFS.Adapter.S3
alias Jido.Workspace.Examples.StoreS3Artifact

destination = S3.configure(bucket: bucket_name, prefix: "workspace-results", config: host_s3_config)
{:ok, digest} = StoreS3Artifact.put(destination, report)
{:ok, ^report} = StoreS3Artifact.fetch(destination, digest)
```

The artifact key contains the SHA-256 digest of the file. The host
publishes the digest to consumers after `put/2` returns success. That
reference can be used after the workspace closes or the BEAM restarts.
The consumer needs the same bucket and prefix and read permission.

The example reads a small file and sends it in one conditional PUT.
The server creates the key only if it is absent. If it returns HTTP 412,
the helper reads the existing object and checks its digest. Matching
content is success. Incorrect content returns `:artifact_digest_mismatch`.
[Amazon S3 conditional writes](https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes.html)

After a connection failure, retry with the same approved bytes. If the
connection ended during upload, the retry can create the missing object.
If the server accepted the object before the connection ended, the retry
can verify it. The earlier artifact stays available under its own digest.
The host controls which digest consumers receive as the current result.

## Run the integration tests

Put a MinIO executable with conditional PUT support on `PATH`. The test
helper starts a loopback server with its own data directory. To build the
version used for this check with Go, run these commands.

```sh
export S3_FIXTURE_BIN=$(mktemp -d)
CGO_ENABLED=0 GOBIN="$S3_FIXTURE_BIN" go install github.com/minio/minio@RELEASE.2025-04-22T22-12-26Z
export PATH="$S3_FIXTURE_BIN:$PATH"
```

To repeat the Docker review, set `JIDO_SANDBOX_DOCKER=1` and use a local
Alpine image.

```sh
JIDO_SANDBOX_DOCKER=1 JIDO_SANDBOX_IMAGE=alpine:3.20 mix test \
  examples/07_keep_useful_results/07_03_store_a_selected_artifact_in_s3/example_test.exs \
  --include integration --include s3
```

The tests interrupt a real PUT after sending part of its body and discard
the reply to another PUT after MinIO commits it. They check what an
independent reader sees before and after retry. A scoped MinIO session
also demonstrates server-side denial of reads and writes to an adjacent
prefix. The evidence covers the local fixture and the single PUT path.
The test profiles also permit `cat` so both runtimes can check that the
command reads the same bytes from the read-only tree.
[Example code](example.ex) · [Tests](example_test.exs)
