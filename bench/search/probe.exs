Code.require_file("support.exs", __DIR__)
Code.require_file("probes.exs", __DIR__)

defmodule SearchSpike.ProbeRun do
  @moduledoc false
  alias Jido.Workspace
  alias SearchSpike.{Fixture, Probes}
  @sizes %{"small" => 1, "medium" => 16, "large" => 128}
  @queries [
    {"literal_miss", "literal", "absent_token"},
    {"literal_rare", "literal", "needle_rare"},
    {"regex_miss", "regex", "missing_[0-9]+"},
    {"regex_rare", "regex", "status=error code=E[0-9]{3}"},
    {"literal_common", "literal", "common_token"},
    {"regex_common", "regex", "handle_request\\(input\\)"}
  ]

  def main(args) do
    {opts, [], []} =
      OptionParser.parse(args,
        strict: [sizes: :string, runs: :integer, dense: :boolean, output: :string]
      )

    sizes = Keyword.get(opts, :sizes, "medium,large") |> String.split(",")
    Enum.each(sizes, &Map.fetch!(@sizes, &1))
    runs = Keyword.get(opts, :runs, 3)
    if runs < 3, do: raise("Use at least three samples")
    dense = Keyword.get(opts, :dense, false)
    rg = System.find_executable("rg") || raise("rg is required")
    bash = System.find_executable("bash") || raise("bash is required")
    {version, 0} = System.cmd(rg, ["--version"])
    {bash_version, 0} = System.cmd(bash, ["--version"])
    :rand.seed(:exsss, {101, 202, 303})

    metadata = %{
      date: DateTime.utc_now() |> DateTime.to_iso8601(),
      runs: runs,
      rg: hd(String.split(version, "\n")),
      rg_path: rg,
      bash: hd(String.split(bash_version, "\n")),
      elixir: System.version(),
      otp: System.otp_release(),
      schedulers: System.schedulers_online(),
      architecture: to_string(:erlang.system_info(:system_architecture)),
      cache: "warm",
      dense: dense,
      output: "all matching lines",
      file_bytes: 16_384,
      snapshot: "frozen file binaries; preparation excluded except fresh_offsets_4"
    }

    results = Enum.map(sizes, &run_size(&1, runs, dense, bash, rg))
    output = Path.expand(Keyword.get(opts, :output, "bench/search/results/probes.json"))
    File.mkdir_p!(Path.dirname(output))
    File.write!(output, Jason.encode!(%{metadata: metadata, results: results}, pretty: true))
    IO.puts("Results: #{output}")
  end

  defp run_size(size, runs, dense, bash, rg) do
    root = Path.join(System.tmp_dir!(), "search-probe-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {:ok, workspace} = Workspace.open()
    sessions_key = make_ref()
    Process.put(sessions_key, [])

    try do
      files = div(Map.fetch!(@sizes, size) * 1_048_576, 16_384)
      IO.puts("Preparing #{size}: #{files} files")

      for index <- 1..files do
        directory = "group_#{div(index - 1, 64)}"
        File.mkdir_p!(Path.join(root, directory))

        File.write!(
          Path.join([root, directory, "file_#{index}.txt"]),
          Fixture.content(index, 16_384)
        )
      end

      {load_us, _} = :timer.tc(fn -> load(workspace, root, "/") end)
      {snapshot_us, frozen} = :timer.tc(fn -> Probes.snapshot(workspace.id) end)
      bytes = Enum.reduce(frozen, 0, fn {_, content}, sum -> sum + byte_size(content) end)
      if length(frozen) != files or bytes != files * 16_384, do: raise("Incomplete snapshot")

      variants =
        [
          {"vfs_lines_1", &SearchSpike.Backend.search/3},
          {"snapshot_lines_1",
           fn _, mode, pattern -> Probes.search(frozen, mode, pattern, :lines, 1) end}
        ] ++
          Enum.map([1, 2, 4, 8], fn workers ->
            {"snapshot_offsets_#{workers}",
             fn _, mode, pattern -> Probes.search(frozen, mode, pattern, :offsets, workers) end}
          end) ++
          [
            {"fresh_offsets_4",
             fn id, mode, pattern ->
               Probes.search(Probes.snapshot(id), mode, pattern, :offsets, 4)
             end}
          ]

      sessions =
        Enum.map(variants, fn {name, search} ->
          {:ok, session} =
            Jido.Shell.ShellSession.start(workspace.id,
              backend: {SearchSpike.Backend, %{search: search}}
            )

          Process.put(sessions_key, [session | Process.get(sessions_key)])
          {name, session}
        end)

      queries = if dense, do: @queries, else: Enum.take(@queries, 4)

      results =
        Enum.map(queries, fn {name, mode, pattern} ->
          jobs =
            [{"bash_rg", fn -> rg_search(bash, rg, root, mode, pattern) end}] ++
              Enum.map(sessions, fn {engine, session} ->
                {engine,
                 fn ->
                   {:ok, output} =
                     Jido.Shell.Agent.run(session, "grep #{mode} #{pattern}", timeout: 300_000)

                   output
                 end}
              end)

          expected = rg_search(bash, rg, root, mode, pattern) |> Fixture.normalized()
          Enum.each(jobs, fn {engine, fun} -> verify!(engine, fun.(), expected) end)

          samples =
            Enum.reduce(1..runs, %{}, fn _, acc ->
              Enum.reduce(Enum.shuffle(jobs), acc, fn {engine, fun}, acc ->
                {us, output} = :timer.tc(fun)
                verify!(engine, output, expected)
                Map.update(acc, engine, [us / 1000], &[us / 1000 | &1])
              end)
            end)

          stats =
            Map.new(samples, fn {engine, times} ->
              sorted = Enum.sort(times)
              count = length(sorted)
              median = (Enum.at(sorted, div(count - 1, 2)) + Enum.at(sorted, div(count, 2))) / 2

              {engine,
               %{
                 median_ms: median,
                 samples_ms: Enum.reverse(times),
                 min_ms: hd(sorted),
                 max_ms: List.last(sorted)
               }}
            end)

          IO.puts(
            "#{size} #{name}: " <>
              Enum.map_join(Enum.sort(stats), " ", fn {engine, result} ->
                "#{engine}=#{Float.round(result.median_ms, 2)}ms"
              end)
          )

          %{name: name, pattern: pattern, mode: mode, matches: length(expected), engines: stats}
        end)

      %{
        size: size,
        files: files,
        bytes: bytes,
        memory_load_ms: load_us / 1000,
        snapshot_ms: snapshot_us / 1000,
        queries: results
      }
    after
      Enum.each(Process.delete(sessions_key), &Jido.Shell.ShellSession.stop/1)
      Workspace.close(workspace)
      File.rm_rf!(root)
    end
  end

  defp load(workspace, root, path) do
    for entry <- File.ls!(root) do
      source = Path.join(root, entry)
      target = Path.join(path, entry)

      if File.dir?(source) do
        :ok = Workspace.mkdir(workspace, target)
        load(workspace, source, target)
      else
        :ok = Workspace.write(workspace, target, File.read!(source))
      end
    end
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
      ] ++
        if(mode == "literal", do: ["--fixed-strings"], else: [])

    {output, status} =
      System.cmd(
        bash,
        ["--noprofile", "--norc", "-c", "exec \"$@\"", "search-probe", rg] ++
          args ++ ["--", pattern, "."],
        cd: root,
        stderr_to_stdout: true
      )

    if status not in [0, 1], do: raise("rg failed: #{output}")
    output
  end

  defp verify!(engine, output, expected) do
    if Fixture.normalized(output) != expected, do: raise("Results differ: #{engine}")
  end
end

SearchSpike.ProbeRun.main(System.argv())
