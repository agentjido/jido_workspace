Code.require_file("support.exs", __DIR__)

defmodule SearchSpike.Run do
  @moduledoc false
  alias Jido.Workspace
  alias SearchSpike.Fixture
  @sizes %{"small" => 1, "medium" => 16, "large" => 128}
  @queries [
    {"literal_miss", "literal", "absent_token"},
    {"literal_rare", "literal", "needle_rare"},
    {"literal_common", "literal", "common_token"},
    {"regex_miss", "regex", "missing_[0-9]+"},
    {"regex_rare", "regex", "status=error code=E[0-9]{3}"},
    {"regex_common", "regex", "handle_request\\(input\\)"}
  ]

  def main(args) do
    {opts, [], []} =
      OptionParser.parse(args, strict: [sizes: :string, runs: :integer, output: :string])

    runs = Keyword.get(opts, :runs, 7)
    if runs < 2, do: raise("Use at least two runs")
    sizes = opts |> Keyword.get(:sizes, "small,medium,large") |> String.split(",")
    Enum.each(sizes, &Map.fetch!(@sizes, &1))
    output = Path.expand(Keyword.get(opts, :output, "bench/search/results/latest.json"))
    rg = System.find_executable("rg") || raise("rg is required on PATH")
    bash = System.find_executable("bash") || raise("bash is required on PATH")
    {version, 0} = System.cmd(rg, ["--version"])

    metadata = %{
      date: DateTime.utc_now() |> DateTime.to_iso8601(),
      os: inspect(:os.type()),
      architecture: to_string(:erlang.system_info(:system_architecture)),
      otp: System.otp_release(),
      elixir: System.version(),
      schedulers: System.schedulers_online(),
      rg: String.split(version, "\n") |> hd(),
      runs: runs,
      file_bytes: 16_384,
      cache: "warm; no OS cache reset",
      output: "all matching lines",
      shell_search: "benchmark-only serial Elixir backend; not a built-in grep command"
    }

    results = Enum.map(sizes, &run_size(&1, runs, rg, bash))
    File.mkdir_p!(Path.dirname(output))
    File.write!(output, Jason.encode!(%{metadata: metadata, results: results}, pretty: true))
    IO.puts("Results: #{output}")
  end

  defp run_size(size, runs, rg, bash) do
    root = Path.join(System.tmp_dir!(), "search-spike-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {:ok, memory} = Workspace.open()
    {:ok, local} = Workspace.open(adapter: Jido.VFS.Adapter.Local, adapter_opts: [prefix: root])

    try do
      files = div(Map.fetch!(@sizes, size) * 1_048_576, 16_384)
      IO.puts("Preparing #{size}: #{files} files")

      {disk_us, _} =
        :timer.tc(fn ->
          for index <- 1..files do
            directory = Path.join(root, "group_#{div(index - 1, 64)}")
            File.mkdir_p!(directory)
            File.write!(Path.join(directory, "file_#{index}.txt"), Fixture.content(index, 16_384))
          end
        end)

      :erlang.garbage_collect()
      before_bytes = :erlang.memory(:total)
      {load_us, _} = :timer.tc(fn -> load_memory(memory, root, "/") end)
      :erlang.garbage_collect()
      memory_delta = :erlang.memory(:total) - before_bytes
      {:ok, memory_session} = Workspace.start_session(memory, backend: {SearchSpike.Backend, %{}})
      {:ok, local_session} = Workspace.start_session(local, backend: {SearchSpike.Backend, %{}})

      queries =
        Enum.map(@queries, fn {name, mode, pattern} ->
          jobs = [
            {"bash_rg", fn -> rg_search(bash, rg, root, mode, pattern) end},
            {"shell_local", fn -> shell_search(local_session, mode, pattern) end},
            {"shell_memory", fn -> shell_search(memory_session, mode, pattern) end}
          ]

          # Validate and warm every path before measured runs.
          expected = jobs |> hd() |> elem(1) |> then(& &1.()) |> Fixture.normalized()
          Enum.each(jobs, fn {_, fun} -> equal!(fun.(), expected) end)

          samples =
            Enum.reduce(1..runs, %{}, fn _, acc ->
              Enum.reduce(Enum.shuffle(jobs), acc, fn {engine, fun}, acc ->
                {us, result} = :timer.tc(fun)
                equal!(result, expected)
                Map.update(acc, engine, [us], &[us | &1])
              end)
            end)

          stats = Map.new(samples, fn {engine, values} -> {engine, stats(values)} end)
          ratio = stats["shell_memory"].median_ms / stats["bash_rg"].median_ms

          IO.puts(
            "#{size} #{name}: rg=#{stats["bash_rg"].median_ms}ms memory=#{stats["shell_memory"].median_ms}ms ratio=#{Float.round(ratio, 2)}"
          )

          %{
            name: name,
            mode: mode,
            pattern: pattern,
            matches: length(expected),
            memory_over_rg: ratio,
            engines: stats
          }
        end)

      %{
        size: size,
        files: files,
        bytes: files * 16_384,
        disk_generate_ms: disk_us / 1000,
        memory_load_ms: load_us / 1000,
        beam_memory_delta_bytes: memory_delta,
        queries: queries
      }
    after
      Workspace.close(memory)
      Workspace.close(local)
      File.rm_rf!(root)
    end
  end

  defp load_memory(workspace, root, path) do
    for entry <- File.ls!(root) do
      source = Path.join(root, entry)
      target = Path.join(path, entry)

      if File.dir?(source) do
        :ok = Workspace.mkdir(workspace, target)
        load_memory(workspace, source, target)
      else
        :ok = Workspace.write(workspace, target, File.read!(source))
      end
    end
  end

  defp shell_search(session, mode, pattern) do
    {:ok, output} = Jido.Shell.Agent.run(session, "grep #{mode} #{pattern}", timeout: 300_000)
    output
  end

  defp rg_search(bash, rg, root, mode, pattern) do
    args =
      [
        "--no-config",
        "--color=never",
        "--no-heading",
        "--with-filename",
        "--line-number",
        "--text",
        "--hidden",
        "--no-ignore"
      ] ++ if(mode == "literal", do: ["--fixed-strings"], else: [])

    # Positional arguments preserve spaces and shell metacharacters in patterns.
    {output, status} =
      System.cmd(
        bash,
        ["--noprofile", "--norc", "-c", "exec \"$@\"", "search-spike", rg] ++
          args ++ ["--", pattern, "."],
        cd: root,
        stderr_to_stdout: true
      )

    if status not in [0, 1], do: raise("rg failed: #{output}")
    output
  end

  defp equal!(output, expected) do
    if Fixture.normalized(output) != expected, do: raise("Search results differ")
  end

  defp stats(values) do
    sorted = Enum.sort(values)
    count = length(sorted)
    middle = div(count, 2)

    median =
      if rem(count, 2) == 1,
        do: Enum.at(sorted, middle),
        else: (Enum.at(sorted, middle - 1) + Enum.at(sorted, middle)) / 2

    %{
      median_ms: median / 1000,
      p95_ms: Enum.at(sorted, ceil(count * 0.95) - 1) / 1000,
      samples_ms: Enum.map(values, &(&1 / 1000))
    }
  end
end

SearchSpike.Run.main(System.argv())
