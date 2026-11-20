Code.require_file("../../05_lifecycle/support.exs", __DIR__)
Code.require_file("../../05_lifecycle/05_04_inspect_state/example.ex", __DIR__)
Code.require_file("example.ex", __DIR__)

defmodule Jido.Workspace.Examples.VerifyCredentialTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :tmp_dir

  alias Jido.Workspace
  alias Jido.Workspace.{Error, Execution}
  alias Jido.Workspace.Examples.{ObserveCommand, VerifyCredential}
  import Jido.Workspace.Examples.LifecycleSupport

  setup %{tmp_dir: root}, do: configure(Path.join(root, "snapshots"))

  test "memory refuses a profile that requires a command input pipe" do
    configure_profile(:credential, %{
      provider: :memory,
      policy: [:read, :execute, :save],
      require: %{stdin: :pipe}
    })

    assert {:error, %Error{operation: :open, code: :unsupported_capability}} =
             Workspace.open(profile: :credential)
  end

  if System.get_env("JIDO_SANDBOX_DOCKER") != "1" do
    @tag skip: "Set JIDO_SANDBOX_DOCKER=1 to test a scoped input pipe on a local engine"
  end

  test "Docker scopes the credential to one command and keeps it out of retained results",
       %{tmp_dir: root} do
    checkout = Path.join(root, "checkout")
    script = install_verifier(checkout)
    image = System.get_env("JIDO_SANDBOX_IMAGE", "alpine:latest")
    configure_profile(:credential, VerifyCredential.profile(checkout, image))
    fixture = "credential-" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    with_workspace([profile: :credential], fn workspace ->
      {controller, sandbox} = provider(workspace, :native)
      clean_up_docker_on_failure(sandbox)
      assert {:ok, before_run} = Workspace.save(workspace)

      assert {:error, %Error{operation: :run, code: :policy_denied}} =
               Workspace.run(workspace, ["/bin/sh"], stdin: :pipe)

      assert {:ok, observer} = ObserveCommand.attach(workspace)

      try do
        task = Task.async(fn -> VerifyCredential.run(workspace) end)
        assert_receive {:workspace_command, :start, _, %{execution_id: id}} = started, 5_000

        assert :ok = :sys.log(controller, {true, 100})
        assert :ok = :sys.log(sandbox.pid, {true, 100})

        assert {:error, %Error{operation: :input, code: :execution_not_active} = refused} =
                 VerifyCredential.submit(workspace, "previous-command", fixture)

        submit_when_ready(workspace, id, fixture)

        assert Enum.any?(redacted_events(controller, fixture), fn
                 {:in, {:"$gen_call", _, {:command_input, ^id, :redacted}}} -> true
                 _ -> false
               end)

        count = 2 * (byte_size(fixture) + 1)
        assert %{bytes: "", dropped_bytes: ^count} = await_discard(workspace, id, count)

        assert Enum.any?(redacted_events(sandbox.pid, fixture), fn
                 {:in, {port, {:data, :redacted}}} when is_port(port) -> true
                 _ -> false
               end)

        assert [container] = containers(sandbox, ["--filter", "status=running"])
        template = "{{.HostConfig.LogConfig.Type}} {{json .Config}}"
        assert {"none " <> config, 0} = docker(["inspect", "--format", template, container])
        refute contains_fixture?(config, fixture)

        assert :ok = Workspace.input(workspace, id, "finish\n")

        assert {:ok,
                %Execution{
                  id: ^id,
                  command: ["/workspace/bin/verify"],
                  status: :exited,
                  exit_status: 0,
                  output: "",
                  truncated: true
                } = result} = Task.await(task, 10_000)

        assert_receive {:workspace_command, :stop, _, %{execution_id: ^id, exit_status: 0}} =
                         stopped

        assert {:ok, %{bytes: "", next_offset: ^count, dropped_bytes: ^count, done?: true}} =
                 Workspace.output(workspace, id)

        assert {:error, %Error{operation: :input, code: :execution_not_active} = late} =
                 VerifyCredential.submit(workspace, id, fixture)

        refute contains_fixture?([started, stopped, result, refused, late], fixture)
      after
        :telemetry.detach(observer)
      end

      assert {:error, %Error{code: :not_found}} = Workspace.read(workspace, "spill.txt")
      assert {:ok, ^before_run} = Workspace.save(workspace)

      reference = Jason.encode!(before_run)
      refute contains_fixture?(reference, fixture)

      with_workspace([profile: :memory, from: Jason.decode!(reference)], fn restored ->
        assert {:ok, ^script} = Workspace.read(restored, "bin/verify")
        assert {:error, %Error{code: :not_found}} = Workspace.read(restored, "spill.txt")
      end)
    end)
  end

  defp configure_profile(name, profile) do
    profiles = Application.fetch_env!(:jido_workspace, :profiles)
    Application.put_env(:jido_workspace, :profiles, Map.put(profiles, name, profile))
  end

  defp install_verifier(checkout) do
    script = ~S"""
    #!/bin/sh
    IFS= read -r fixture || exit 2
    case "$fixture" in
      credential-*) ;;
      *) exit 3 ;;
    esac
    printf '%s\n' "$fixture"
    printf '%s\n' "$fixture" >&2
    if (printf '%s\n' "$fixture" > /workspace/spill.txt) 2>/dev/null; then
      exit 4
    fi
    IFS= read -r done || exit 5
    [ "$done" = finish ]
    """

    path = Path.join(checkout, "bin/verify")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, script)
    File.chmod!(path, 0o755)
    script
  end

  defp submit_when_ready(workspace, id, fixture) do
    await(
      fn ->
        case VerifyCredential.submit(workspace, id, fixture) do
          :ok -> true
          {:error, %Error{code: code}} when code in [:input_not_ready, :input_busy] -> false
          {:error, error} -> flunk("Input failed with #{error.code}")
        end
      end,
      "The program did not accept input",
      5_000
    )
  end

  defp await_discard(workspace, id, count) do
    await(
      fn ->
        case Workspace.output(workspace, id) do
          {:ok, %{next_offset: ^count, done?: false} = slice} -> slice
          _ -> nil
        end
      end,
      "The program did not emit the expected bytes before exit",
      5_000
    )
  end

  defp redacted_events(pid, fixture) do
    {:status, ^pid, {:module, :gen_server}, [_, _, _, _, formatted]} = :sys.get_status(pid)
    refute contains_fixture?(formatted, fixture), "Formatted status exposed the credential"
    data = formatted |> Keyword.get_values(:data) |> Enum.concat()
    {~c"Logged events", events} = List.keyfind(data, ~c"Logged events", 0)
    events
  end

  defp contains_fixture?(term, fixture) do
    :binary.match(:erlang.term_to_binary(term), fixture) != :nomatch
  end

  defp with_workspace(options, fun) do
    assert {:ok, workspace} = Workspace.open(options)

    try do
      fun.(workspace)
    after
      assert :ok = Workspace.close(workspace)
    end
  end
end
