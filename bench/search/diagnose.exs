Code.require_file("support.exs", __DIR__)
Code.require_file("probes.exs", __DIR__)
Code.require_file("real_support.exs", __DIR__)

defmodule SearchSpike.Diagnose do
  @moduledoc false
  alias SearchSpike.{Fixture, Probes, RealCorpus}
  @pattern "[A-Za-z_]+\\.start_link\\("
  @required ".start_link("
  @absent "beam_search_absent_9f02b71d"

  def main do
    previous = File.read!("bench/search/results/real.json") |> Jason.decode!()
    source = previous["metadata"]["source"]

    files =
      Enum.map(previous["corpus"]["manifest"], fn item ->
        content = File.read!(Path.join(source, item["path"]))

        if RealCorpus.hash(content) != item["sha256"],
          do: raise("Source changed: #{item["path"]}")

        {"/" <> item["path"], content}
      end)

    IO.puts("Verified #{length(files)} files against the real-test manifest")

    root =
      Path.join(
        System.tmp_dir!(),
        "search-diagnose-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
      )

    tree = Path.join(root, "tree")
    File.mkdir_p!(tree)
    rg = System.find_executable("rg")
    bash = System.find_executable("bash")
    Process.put(:diagnose_sessions, [])

    try do
      for {path, content} <- files do
        target = Path.join(tree, String.trim_leading(path, "/"))
        File.mkdir_p!(Path.dirname(target))
        File.write!(target, content)
      end

      # The absent literal cannot match across boundaries; verify zero results.
      single = Path.join(root, "joined.txt")

      File.open!(single, [:write, :binary], fn io ->
        Enum.each(files, fn {_, content} -> IO.binwrite(io, content) end)
      end)

      IO.puts("Profiling the start_link regex once per file")
      regex = Regex.compile!(@pattern, "m")

      profile =
        Enum.map(files, fn {path, content} ->
          {us, matches} =
            :timer.tc(fn -> Regex.scan(regex, content, return: :index, capture: :first) end)

          %{
            path: path,
            bytes: byte_size(content),
            regex_ms: us / 1000,
            matches: length(matches),
            required_literal: :binary.match(content, @required) != :nomatch
          }
        end)

      total = Enum.sum(Enum.map(profile, & &1.regex_ms))
      rejected = Enum.reject(profile, & &1.required_literal)
      rejected_ms = Enum.sum(Enum.map(rejected, & &1.regex_ms))

      IO.puts(
        "Regex total #{Float.round(total, 2)}ms; files without required literal #{Float.round(rejected_ms, 2)}ms"
      )

      native =
        session(fn _, mode, pattern -> Probes.search(files, mode, pattern, :offsets, 8) end)

      gated = session(fn _, mode, pattern -> gated(files, mode, pattern) end)
      expected = rg_search(bash, rg, tree, @pattern, false, ".") |> Fixture.normalized()

      regex_jobs = [
        {"bash_rg", fn -> rg_search(bash, rg, tree, @pattern, false, ".") end},
        {"beam_8", fn -> shell(native, "regex", @pattern) end},
        {"beam_8_required_literal", fn -> shell(gated, "regex", @pattern) end}
      ]

      regex_results = measure(regex_jobs, expected)

      absent_jobs = [
        {"bash_true",
         fn ->
           {"", 0} = System.cmd(bash, ["--noprofile", "--norc", "-c", "true"])
           ""
         end},
        {"rg_tree", fn -> rg_search(bash, rg, tree, @absent, true, ".") end},
        {"rg_one_file_same_bytes",
         fn -> rg_search(bash, rg, root, @absent, true, "joined.txt") end},
        {"beam_8", fn -> shell(native, "literal", @absent) end}
      ]

      absent_results = measure(absent_jobs, [])
      # Separate enumeration from content search. This is not an additive model.
      listing_jobs = [
        {"bash_rg_files",
         fn ->
           {output, 0} = bash_rg(bash, rg, ["--files", "--hidden", "--no-ignore", "."], tree)
           output
         end}
      ]

      listing_expected = Enum.map(files, fn {path, _} -> "." <> path end) |> Enum.sort()
      listing_results = measure(listing_jobs, listing_expected)

      result = %{
        metadata: %{
          date: DateTime.utc_now() |> DateTime.to_iso8601(),
          regex_version: to_string(:re.version()),
          manifest_sha256: previous["corpus"]["manifest_sha256"],
          profile_runs: 1,
          timing_runs: 5,
          cache: "warm"
        },
        profile: %{
          total_ms: total,
          files_without_required_literal: length(rejected),
          time_without_required_literal_ms: rejected_ms,
          candidate_files: length(files) - length(rejected),
          top_files: Enum.sort_by(profile, & &1.regex_ms, :desc) |> Enum.take(15)
        },
        regex: regex_results,
        absent: absent_results,
        enumeration: listing_results
      }

      File.write!("bench/search/results/diagnosis.json", Jason.encode!(result, pretty: true))
      IO.puts("Saved bench/search/results/diagnosis.json")
    after
      Enum.each(Process.get(:diagnose_sessions), &Jido.Shell.ShellSession.stop/1)
      File.rm_rf!(root)
    end
  end

  defp gated(files, mode, pattern) do
    # This required literal is valid only for the one regex under diagnosis.
    if mode != "regex" or pattern != @pattern, do: raise("Unsupported diagnostic query")

    files
    |> Enum.chunk_every(ceil(length(files) / 8))
    |> Task.async_stream(
      fn batch ->
        selected =
          Enum.filter(batch, fn {_, data} -> :binary.match(data, @required) != :nomatch end)

        Probes.search(selected, mode, pattern, :offsets, 1)
      end,
      max_concurrency: 8,
      ordered: false,
      timeout: 300_000
    )
    |> Enum.map(fn {:ok, output} -> output end)
    |> IO.iodata_to_binary()
  end

  defp session(search) do
    {:ok, id} =
      Jido.Shell.ShellSession.start("search-diagnose",
        backend: {SearchSpike.Backend, %{search: search}}
      )

    Process.put(:diagnose_sessions, [id | Process.get(:diagnose_sessions)])
    id
  end

  defp shell(session, mode, pattern) do
    {:ok, output} = Jido.Shell.Agent.run(session, "grep #{mode} #{pattern}", timeout: 300_000)
    output
  end

  defp rg_search(bash, rg, cwd, pattern, literal, target) do
    args =
      [
        "--no-config",
        "--color=never",
        "--encoding=none",
        "--text",
        "--hidden",
        "--no-ignore",
        "--no-heading",
        "--line-number",
        "--with-filename"
      ] ++
        if(literal, do: ["--fixed-strings"], else: [])

    {output, status} = bash_rg(bash, rg, args ++ ["--", pattern, target], cwd)
    if status not in [0, 1], do: raise("rg failed")
    output
  end

  defp bash_rg(bash, rg, args, cwd) do
    System.cmd(
      bash,
      ["--noprofile", "--norc", "-c", "exec \"$@\"", "search-diagnose", rg] ++ args,
      cd: cwd,
      stderr_to_stdout: true
    )
  end

  defp measure(jobs, expected) do
    Enum.each(jobs, fn {name, fun} -> verify!(name, fun.(), expected) end)

    samples =
      Enum.reduce(1..5, %{}, fn _, acc ->
        Enum.reduce(Enum.shuffle(jobs), acc, fn {name, fun}, acc ->
          {us, output} = :timer.tc(fun)
          verify!(name, output, expected)
          Map.update(acc, name, [us / 1000], &[us / 1000 | &1])
        end)
      end)

    Map.new(samples, fn {name, times} ->
      median = times |> Enum.sort() |> Enum.at(2)
      IO.puts("#{name}: #{Float.round(median, 2)}ms")
      {name, %{median_ms: median, samples_ms: Enum.reverse(times)}}
    end)
  end

  defp verify!(name, output, expected) do
    if Fixture.normalized(output) != expected, do: raise("Diagnostic results differ: #{name}")
  end
end

SearchSpike.Diagnose.main()
