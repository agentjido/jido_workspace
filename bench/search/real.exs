Code.require_file("support.exs", __DIR__)
Code.require_file("probes.exs", __DIR__)
Code.require_file("real_support.exs", __DIR__)

defmodule SearchSpike.RealRun do
  @moduledoc false
  alias Jido.Workspace
  alias SearchSpike.{Fixture, Probes, RealCorpus}

  @queries [
    {"absent", "literal", "beam_search_absent_9f02b71d"},
    {"project_name", "literal", "BeamWeaver"},
    {"server_call", "literal", "GenServer.call"},
    {"callback", "literal", "handle_call"},
    {"module_definition", "literal", "defmodule"},
    {"todo", "literal", "TODO"},
    {"function_definition", "regex", "^[ \\t]*defp?[ \\t]+[a-z_][a-zA-Z0-9_!?]*"},
    {"callbacks", "regex", "handle_(call|cast|info)"},
    {"error_tuple", "regex", "\\{:error,[ \\t]*:[a-z_]+"},
    {"start_link", "regex", "[A-Za-z_]+\\.start_link\\("}
  ]
  @outputs [{"lines", []}, {"files", [output: :files]}, {"five_per_file", [max_per_file: 5]}]

  def main(args) do
    {opts, [], []} =
      OptionParser.parse(args, strict: [source: :string, runs: :integer, output: :string])

    source = Path.expand(Keyword.get(opts, :source, "../beam_weaver"))
    runs = Keyword.get(opts, :runs, 3)
    if runs < 3, do: raise("Use at least three repeats")
    result_path = Path.expand(Keyword.get(opts, :output, "bench/search/results/real.json"))
    rg = System.find_executable("rg") || raise("rg is required")
    bash = System.find_executable("bash") || raise("bash is required")
    {version, 0} = System.cmd(rg, ["--version"])

    root =
      Path.join(
        System.tmp_dir!(),
        "search-real-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
      )

    File.mkdir_p!(root)
    {:ok, workspace} = Workspace.open()
    Process.put(:real_sessions, [])
    :rand.seed(:exsss, {901, 902, 903})

    try do
      IO.puts("Copying selected text files from #{source}")
      {copy_us, manifest} = :timer.tc(fn -> RealCorpus.freeze(source, root) end)
      bytes = Enum.sum(Enum.map(manifest, & &1.bytes))
      IO.puts("Corpus: #{length(manifest)} files, #{Float.round(bytes / 1_048_576, 2)} MiB")
      {load_us, _} = :timer.tc(fn -> RealCorpus.load(workspace, root, manifest) end)
      {snapshot_us, frozen} = :timer.tc(fn -> Probes.snapshot(workspace.id) end)
      verify_snapshot!(frozen, manifest)
      IO.puts("Loaded VFS in #{load_us / 1000}ms; file view in #{snapshot_us / 1000}ms")

      base = %{
        metadata: %{
          source: source,
          date: DateTime.utc_now() |> DateTime.to_iso8601(),
          rg: hd(String.split(version, "\n")),
          elixir: System.version(),
          otp: System.otp_release(),
          schedulers: System.schedulers_online(),
          architecture: to_string(:erlang.system_info(:system_architecture)),
          runs: runs,
          cache: "warm",
          encoding: "raw UTF-8 bytes; no BOM removal"
        },
        corpus: %{
          files: length(manifest),
          bytes: bytes,
          manifest: manifest,
          manifest_sha256: RealCorpus.hash(Jason.encode!(manifest)),
          copy_ms: copy_us / 1000,
          vfs_load_ms: load_us / 1000,
          snapshot_ms: snapshot_us / 1000
        },
        queries: []
      }

      save(result_path, base)

      queries =
        Enum.flat_map(@outputs, fn {output_name, search_opts} ->
          sessions = sessions(workspace, frozen, search_opts, output_name == "lines")

          results =
            Enum.map(@queries, fn {name, mode, pattern} ->
              jobs = jobs(sessions, bash, rg, root, mode, pattern, output_name)
              expected_output = rg_search(bash, rg, root, mode, pattern, output_name)
              expected = Fixture.normalized(expected_output)
              Enum.each(jobs, fn {engine, fun} -> verify!(engine, fun.(), expected) end)
              stats = measure(jobs, runs, expected)

              IO.puts(
                "#{output_name}/#{name}: " <>
                  Enum.map_join(Enum.sort(stats), " ", fn {engine, s} ->
                    "#{engine}=#{Float.round(s.median_ms, 2)}ms"
                  end)
              )

              %{
                name: name,
                mode: mode,
                pattern: pattern,
                output: output_name,
                rows: length(expected),
                output_bytes: byte_size(expected_output),
                engines: stats
              }
            end)

          stop_sessions(sessions)
          results
        end)

      base = %{base | queries: queries}
      save(result_path, base)
      batch = batch(workspace, frozen, bash, rg, root, queries)
      save(result_path, Map.put(base, :batch, batch))
      update = update(workspace, frozen, manifest, bash, rg, root)
      save(result_path, base |> Map.put(:batch, batch) |> Map.put(:update, update))
      IO.puts("Results: #{result_path}")
    after
      Enum.each(Process.get(:real_sessions), &Jido.Shell.ShellSession.stop/1)
      Workspace.close(workspace)
      File.rm_rf!(root)
    end
  end

  defp sessions(workspace, frozen, opts, original) do
    variants =
      Enum.map([4, 8], fn workers ->
        {"beam_#{workers}",
         fn _, mode, pattern -> Probes.search(frozen, mode, pattern, :offsets, workers, opts) end}
      end)

    variants =
      if original,
        do: [{"original_beam", &SearchSpike.Backend.search/3} | variants],
        else: variants

    Enum.map(variants, fn {name, search} ->
      {:ok, session} =
        Jido.Shell.ShellSession.start(workspace.id,
          backend: {SearchSpike.Backend, %{search: search}}
        )

      Process.put(:real_sessions, [session | Process.get(:real_sessions)])
      {name, session}
    end)
  end

  defp stop_sessions(sessions) do
    Enum.each(sessions, fn {_, session} ->
      :ok = Jido.Shell.ShellSession.stop(session)
      Process.put(:real_sessions, List.delete(Process.get(:real_sessions), session))
    end)
  end

  defp jobs(sessions, bash, rg, root, mode, pattern, output) do
    [{"bash_rg", fn -> rg_search(bash, rg, root, mode, pattern, output) end}] ++
      Enum.map(sessions, fn {name, session} -> {name, fn -> shell(session, mode, pattern) end} end)
  end

  defp shell(session, mode, pattern) do
    {:ok, output} = Jido.Shell.Agent.run(session, "grep #{mode} #{pattern}", timeout: 300_000)
    output
  end

  defp rg_search(bash, rg, root, mode, pattern, output) do
    flags =
      case output do
        "files" ->
          ["--files-with-matches"]

        "lines" ->
          ["--line-number", "--with-filename", "--no-heading"]

        "five_per_file" ->
          ["--line-number", "--with-filename", "--no-heading", "--max-count", "5"]
      end

    args =
      ["--no-config", "--color=never", "--encoding=none", "--text", "--hidden", "--no-ignore"] ++
        flags ++
        if(mode == "literal", do: ["--fixed-strings"], else: [])

    {output, status} =
      System.cmd(
        bash,
        ["--noprofile", "--norc", "-c", "exec \"$@\"", "search-real", rg] ++
          args ++ ["--", pattern, "."],
        cd: root,
        stderr_to_stdout: true
      )

    if status not in [0, 1], do: raise("rg failed")
    output
  end

  defp measure(jobs, runs, expected) do
    Enum.reduce(1..runs, %{}, fn _, acc ->
      Enum.reduce(Enum.shuffle(jobs), acc, fn {engine, fun}, acc ->
        {us, output} = :timer.tc(fun)
        verify!(engine, output, expected)
        Map.update(acc, engine, [us / 1000], &[us / 1000 | &1])
      end)
    end)
    |> Map.new(fn {engine, times} -> {engine, stats(times)} end)
  end

  defp batch(workspace, frozen, bash, rg, root, results) do
    sessions = sessions(workspace, frozen, [], false)
    expected = Map.new(Enum.filter(results, &(&1.output == "lines")), &{&1.name, &1.output_bytes})

    try do
      Enum.map([1, 10, 100], fn count ->
        sequence = Stream.cycle(@queries) |> Enum.take(count)

        engines =
          [{"bash_rg", fn mode, pattern -> rg_search(bash, rg, root, mode, pattern, "lines") end}] ++
            Enum.map(sessions, fn {name, session} ->
              {name, fn mode, pattern -> shell(session, mode, pattern) end}
            end)

        measured =
          Enum.reduce(1..3, %{}, fn _, acc ->
            Enum.reduce(Enum.shuffle(engines), acc, fn {name, search}, acc ->
              {us, sizes} =
                :timer.tc(fn ->
                  Enum.map(sequence, fn {name, mode, pattern} ->
                    {name, byte_size(search.(mode, pattern))}
                  end)
                end)

              Enum.each(sizes, fn {query, size} ->
                if size != expected[query], do: raise("Batch output size changed")
              end)

              Map.update(acc, name, [us / 1000], &[us / 1000 | &1])
            end)
          end)
          |> Map.new(fn {engine, times} -> {engine, stats(times)} end)

        IO.puts(
          "Batch #{count}: " <>
            inspect(Map.new(measured, fn {k, v} -> {k, Float.round(v.median_ms, 2)} end))
        )

        %{searches: count, engines: measured}
      end)
    after
      stop_sessions(sessions)
    end
  end

  defp update(workspace, frozen, manifest, bash, rg, root) do
    marker = "beam_search_update_6a72c118"

    selected =
      manifest
      |> Enum.filter(&(String.ends_with?(&1.path, ".ex") and &1.bytes < 100_000))
      |> Enum.take(10)

    if length(selected) != 10, do: raise("Need ten source files for update test")

    changes =
      Enum.map(selected, fn item ->
        {item.path, File.read!(Path.join(root, item.path)) <> "\n# " <> marker <> "\n"}
      end)

    {disk_us, _} =
      :timer.tc(fn ->
        Enum.each(changes, fn {path, data} -> File.write!(Path.join(root, path), data) end)
      end)

    {vfs_us, _} =
      :timer.tc(fn ->
        Enum.each(changes, fn {path, data} ->
          :ok = Workspace.write(workspace, "/" <> path, data)
        end)
      end)

    {refresh_us, refreshed} = :timer.tc(fn -> Probes.snapshot(workspace.id) end)

    if Probes.search(frozen, "literal", marker, :offsets, 8) != "",
      do: raise("Frozen view changed")

    sessions = sessions(workspace, refreshed, [], false)

    try do
      expected = rg_search(bash, rg, root, "literal", marker, "lines") |> Fixture.normalized()
      if length(expected) != 10, do: raise("Update result count differs")
      jobs = jobs(sessions, bash, rg, root, "literal", marker, "lines")
      measured = measure(jobs, 3, expected)

      IO.puts(
        "Update: disk=#{disk_us / 1000}ms VFS=#{vfs_us / 1000}ms refresh=#{refresh_us / 1000}ms"
      )

      %{
        paths: Enum.map(selected, & &1.path),
        disk_write_ms: disk_us / 1000,
        vfs_write_ms: vfs_us / 1000,
        full_refresh_ms: refresh_us / 1000,
        search: measured
      }
    after
      stop_sessions(sessions)
    end
  end

  defp verify_snapshot!(files, manifest) do
    actual =
      Map.new(files, fn {path, data} ->
        {String.trim_leading(path, "/"), RealCorpus.hash(data)}
      end)

    expected = Map.new(manifest, &{&1.path, &1.sha256})
    if actual != expected, do: raise("VFS bytes differ from manifest")
  end

  defp verify!(engine, output, expected) do
    if Fixture.normalized(output) != expected,
      do: raise("Results differ for #{engine}; output suppressed")
  end

  defp stats(times) do
    sorted = Enum.sort(times)
    count = length(times)

    %{
      median_ms: (Enum.at(sorted, div(count - 1, 2)) + Enum.at(sorted, div(count, 2))) / 2,
      samples_ms: Enum.reverse(times),
      min_ms: hd(sorted),
      max_ms: List.last(sorted)
    }
  end

  defp save(path, data) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(data, pretty: true))
  end
end

SearchSpike.RealRun.main(System.argv())
