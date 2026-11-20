Code.require_file("../../05_lifecycle/support.exs", __DIR__)
Code.require_file("example.ex", __DIR__)

defmodule Jido.Workspace.Examples.StoreS3ArtifactTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :s3
  @moduletag :tmp_dir
  @moduletag capture_log: true

  if not Application.compile_env(:jido_vfs, :minio_available, false) do
    @moduletag skip: "Start the local MinIO fixture to test S3 publication"
  end

  import SweetXml, only: [sigil_x: 2]

  alias Jido.VFS
  alias Jido.VFS.Adapter.S3
  alias Jido.VFS.Errors.{AdapterError, FileNotFound}
  alias Jido.Workspace
  alias Jido.Workspace.Execution
  alias Jido.Workspace.Examples.{LifecycleSupport, StoreS3Artifact}

  defmodule InterruptedPut do
    @moduledoc false
    @behaviour ExAws.Request.HttpClient

    @impl true
    def request(:put, url, body, headers, options) do
      case Keyword.fetch!(options, :interrupt) do
        :during_upload ->
          truncate(url, body, headers)

        :after_commit ->
          {:ok, %{status_code: 200}} = ExAws.Request.Req.request(:put, url, body, headers)
      end

      {:error, %{reason: :closed}}
    end

    def request(method, url, body, headers, _options),
      do: ExAws.Request.Req.request(method, url, body, headers)

    defp truncate(url, body, headers) do
      %URI{scheme: "http", host: "127.0.0.1", port: port, path: path, query: nil} = URI.parse(url)
      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 5_000)

      try do
        body = IO.iodata_to_binary(body)
        partial = binary_part(body, 0, div(byte_size(body), 2))
        headers = Enum.map(headers, fn {key, value} -> [key, ": ", value, "\r\n"] end)

        :ok =
          :gen_tcp.send(socket, [
            "PUT ",
            path,
            " HTTP/1.1\r\n",
            headers,
            "Content-Length: ",
            Integer.to_string(byte_size(body)),
            "\r\n",
            "Connection: close\r\n\r\n",
            partial
          ])

        :ok = :gen_tcp.shutdown(socket, :write)

        case :gen_tcp.recv(socket, 12, 5_000) do
          {:ok, status} when status in ["HTTP/1.1 400", "HTTP/1.1 499"] -> :ok
          {:error, :closed} -> :ok
        end
      after
        :gen_tcp.close(socket)
      end
    end
  end

  setup %{tmp_dir: root} do
    LifecycleSupport.configure(Path.join(root, "snapshots"))
    %{memory: memory, docker: docker} = Application.fetch_env!(:jido_workspace, :profiles)

    Application.put_env(:jido_workspace, :profiles, %{
      scratch: %{memory | policy: [:read, :write, :save]},
      review: %{memory | policy: [:read, :import, :execute]},
      docker_review: %{docker | policy: [:read, :import, :execute]}
    })

    prefix = "workspace-artifacts/" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    config = JidoVfsTest.Minio.config()
    destination = destination(config, prefix)
    on_exit(fn -> assert :ok = VFS.clear(destination) end)
    %{destination: destination, config: config, prefix: prefix}
  end

  test "exports just the requested file from a saved memory tree", context do
    verify_export(:review, context)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to read the saved file from Docker before upload"
  end

  test "reads the saved file through the same Workspace API on Docker", context do
    verify_export(:docker_review, context)
  end

  test "a broken connection during upload leaves the earlier artifact readable", context do
    %{destination: destination} = context
    earlier = "Earlier report\n"
    assert {:ok, earlier_digest} = StoreS3Artifact.put(destination, earlier)
    candidate = "New report\n" |> save_candidate() |> read_report(:review)
    digest = digest(candidate)

    assert {:error, %AdapterError{reason: :closed}} =
             context |> interrupted(:during_upload) |> StoreS3Artifact.put(candidate)

    assert {:ok, ^earlier} = StoreS3Artifact.fetch(destination, earlier_digest)
    assert {:error, %FileNotFound{}} = StoreS3Artifact.fetch(destination, digest)

    assert {:ok, ^digest} = StoreS3Artifact.put(destination, candidate)
    assert {:ok, ^candidate} = StoreS3Artifact.fetch(destination, digest)
    assert {:ok, ^earlier} = StoreS3Artifact.fetch(destination, earlier_digest)
  end

  test "a lost reply after commit can be retried with the same bytes", context do
    %{destination: destination} = context
    candidate = "One approved report\n" |> save_candidate() |> read_report(:review)
    digest = digest(candidate)

    assert {:error, %AdapterError{reason: :closed}} =
             context |> interrupted(:after_commit) |> StoreS3Artifact.put(candidate)

    assert {:ok, ^candidate} = StoreS3Artifact.fetch(destination, digest)

    assert {:error, %AdapterError{reason: {:http_error, 412, _}}} =
             VFS.write(destination, "sha256/" <> digest, "Replacement", if_none_match: "*")

    assert {:ok, ^digest} = StoreS3Artifact.put(destination, candidate)
    assert keys(context) == [context.prefix <> "/sha256/" <> digest]
  end

  test "a conflicting object with incorrect bytes is refused", %{destination: destination} do
    candidate = "Approved report\n" |> save_candidate() |> read_report(:review)
    digest = digest(candidate)
    assert :ok = VFS.write(destination, "sha256/" <> digest, "Wrong content")

    assert {:error, :artifact_digest_mismatch} = StoreS3Artifact.fetch(destination, digest)
    assert {:error, :artifact_digest_mismatch} = StoreS3Artifact.put(destination, candidate)
    assert {:ok, "Wrong content"} = VFS.read(destination, "sha256/" <> digest)
  end

  test "the object store enforces the host session's prefix", %{config: config, prefix: prefix} do
    scoped = prefix_session(config, prefix)
    approved = destination(scoped, prefix)
    sibling = prefix <> "-other"
    blocked = destination(scoped, sibling)
    fixture = destination(config, sibling)
    on_exit(fn -> assert :ok = VFS.clear(fixture) end)

    candidate = "Approved report\n" |> save_candidate() |> read_report(:review)
    assert {:ok, digest} = StoreS3Artifact.put(approved, candidate)
    assert {:ok, ^candidate} = StoreS3Artifact.fetch(approved, digest)

    other_content = "Sibling report\n"
    assert {:ok, sibling_digest} = StoreS3Artifact.put(fixture, other_content)

    assert {:error, %AdapterError{reason: {:http_error, 403, _}}} =
             StoreS3Artifact.fetch(blocked, sibling_digest)

    assert {:error, %AdapterError{reason: {:http_error, 403, _}}} =
             StoreS3Artifact.put(blocked, candidate)

    assert {:ok, ^other_content} = StoreS3Artifact.fetch(fixture, sibling_digest)
  end

  defp verify_export(
         profile,
         %{destination: destination, config: config, prefix: prefix} = context
       ) do
    report = <<"Approved report\r\n", 0, 255>>
    bytes = report |> save_candidate() |> read_report(profile)
    assert bytes == report
    assert {:ok, digest} = StoreS3Artifact.put(destination, bytes)
    assert digest == digest(report)
    assert keys(context) == [prefix <> "/sha256/" <> digest]
    assert {:ok, ^report} = StoreS3Artifact.fetch(destination, digest)

    nearby = destination(config, prefix <> "-other")
    assert {:error, %FileNotFound{}} = StoreS3Artifact.fetch(nearby, digest)

    assert {:error, :invalid_artifact_digest} =
             StoreS3Artifact.fetch(destination, "../" <> digest)
  end

  defp save_candidate(report) do
    assert {:ok, scratch} = Workspace.open(profile: :scratch)

    try do
      assert :ok = Workspace.write(scratch, "report.txt", report)
      assert :ok = Workspace.write(scratch, "draft.txt", "Private notes")
      assert {:ok, snapshot} = Workspace.save(scratch)
      assert :ok = Workspace.write(scratch, "report.txt", "Unsaved edit")
      snapshot |> Jason.encode!() |> Jason.decode!()
    after
      assert :ok = Workspace.close(scratch)
    end
  end

  defp read_report(reference, profile) do
    assert {:ok, review} = Workspace.open(profile: profile, from: reference)

    try do
      assert {:ok, report} = Workspace.read(review, "report.txt")

      assert {:ok, %Execution{exit_status: 0, output: ^report}} =
               Workspace.run(review, ["cat", "report.txt"])

      report
    after
      assert :ok = Workspace.close(review)
    end
  end

  defp keys(%{prefix: prefix, config: config}) do
    assert {:ok, %{body: body}} =
             ExAws.S3.list_objects_v2("default", prefix: prefix <> "/") |> ExAws.request(config)

    Enum.map(body.contents, & &1.key)
  end

  defp interrupted(%{prefix: prefix, config: config}, phase) do
    config =
      Keyword.merge(config,
        http_client: InterruptedPut,
        http_opts: [interrupt: phase],
        retries: [max_attempts: 1]
      )

    destination(config, prefix)
  end

  defp prefix_session(config, prefix) do
    policy = %{
      "Version" => "2012-10-17",
      "Statement" => [
        %{
          "Effect" => "Allow",
          "Action" => ["s3:GetObject", "s3:PutObject"],
          "Resource" => "arn:aws:s3:::default/#{prefix}/sha256/*"
        }
      ]
    }

    request = %ExAws.Operation.Query{
      service: :sts,
      params: %{
        "Action" => "AssumeRole",
        "DurationSeconds" => "900",
        "Policy" => Jason.encode!(policy),
        "Version" => "2011-06-15"
      }
    }

    assert {:ok, %{body: xml}} = ExAws.request(request, config)

    credentials =
      SweetXml.xmap(xml,
        access_key_id: ~x"//Credentials/AccessKeyId/text()"s,
        secret_access_key: ~x"//Credentials/SecretAccessKey/text()"s,
        security_token: ~x"//Credentials/SessionToken/text()"s
      )

    Keyword.merge(config, Map.to_list(credentials))
  end

  defp destination(config, prefix),
    do: S3.configure(bucket: "default", prefix: prefix, config: config)

  defp digest(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
