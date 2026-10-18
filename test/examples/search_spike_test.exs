Code.require_file("../../bench/search/support.exs", __DIR__)
Code.require_file("../../bench/search/probes.exs", __DIR__)
Code.require_file("../../bench/search/real_support.exs", __DIR__)

defmodule Jido.Workspace.Integration.SearchSpikeTest do
  use ExUnit.Case, async: false
  alias Jido.Workspace
  @moduletag :integration
  @moduletag :search_spike

  test "binary and parallel probes preserve line results on a frozen view" do
    {:ok, workspace} = Workspace.open()

    try do
      for {path, content} <- [
            {"/a.txt", "a.b\naXb\na.b a.b\n\n"},
            {"/last.txt", "last a.b"},
            {"/empty.txt", ""},
            {"/blank.txt", "\n"},
            {"/utf8.txt", "café a.b\nother\n"}
          ] do
        :ok = Workspace.write(workspace, path, content)
      end

      frozen = SearchSpike.Probes.snapshot(workspace.id)

      for {mode, pattern} <- [
            {"literal", "a.b"},
            {"literal", "missing"},
            {"regex", "a.b"},
            {"regex", "^a"},
            {"regex", "a.b$"},
            {"regex", "^$"},
            {"regex", "$"},
            {"regex", "a*"},
            {"regex", "missing_[0-9]+"}
          ] do
        expected =
          SearchSpike.Backend.search(workspace.id, mode, pattern)
          |> SearchSpike.Fixture.normalized()

        for algorithm <- [:lines, :offsets], workers <- [1, 2, 4, 8] do
          actual = SearchSpike.Probes.search(frozen, mode, pattern, algorithm, workers)

          assert SearchSpike.Fixture.normalized(actual) == expected,
                 "#{mode} #{pattern}, #{algorithm}, #{workers} workers"
        end

        for workers <- [4, 8] do
          names = Enum.map(expected, &(String.split(&1, ":", parts: 3) |> hd())) |> Enum.uniq()

          actual =
            SearchSpike.Probes.search(frozen, mode, pattern, :offsets, workers, output: :files)

          assert SearchSpike.Fixture.normalized(actual) == names
          first = Enum.uniq_by(expected, &(String.split(&1, ":", parts: 3) |> hd()))

          limited =
            SearchSpike.Probes.search(frozen, mode, pattern, :offsets, workers, max_per_file: 1)

          assert SearchSpike.Fixture.normalized(limited) == first
        end
      end

      :ok = Workspace.write(workspace, "/a.txt", "changed\n")
      assert {"/a.txt", "a.b\naXb\na.b a.b\n\n"} in frozen
      refute frozen == SearchSpike.Probes.snapshot(workspace.id)
    after
      Workspace.close(workspace)
    end
  end

  @tag :tmp_dir
  test "real corpus includes dependencies and hidden text but excludes binary files and links", %{
    tmp_dir: tmp
  } do
    source = Path.join(tmp, "source")
    target = Path.join(tmp, "copy")
    for dir <- ["deps/pkg", "_build", ".git"], do: File.mkdir_p!(Path.join(source, dir))
    File.write!(Path.join(source, "deps/pkg/file.ex"), "defmodule Example do\nend\n")
    File.write!(Path.join(source, ".hidden"), "hidden\n")
    File.write!(Path.join(source, "_build/generated.txt"), "exclude\n")
    File.write!(Path.join(source, ".git/config"), "exclude\n")
    File.write!(Path.join(source, "binary"), <<0, 1>>)
    File.write!(Path.join(source, "invalid"), <<255>>)
    File.ln_s!(Path.join(source, ".hidden"), Path.join(source, "link"))
    manifest = SearchSpike.RealCorpus.freeze(source, target)
    assert Enum.map(manifest, & &1.path) == [".hidden", "deps/pkg/file.ex"]

    for item <- manifest do
      assert item.sha256 == SearchSpike.RealCorpus.hash(File.read!(Path.join(target, item.path)))
    end
  end

  test "search returns full lines through a Shell session with memory files" do
    {:ok, workspace} = Workspace.open()

    try do
      :ok = Workspace.mkdir(workspace, "/nested")
      :ok = Workspace.write(workspace, "/nested/a.txt", "a.b\naXb\na.b a.b\n\n")
      :ok = Workspace.write(workspace, "/last.txt", "a.b")
      {:ok, session} = Workspace.start_session(workspace, backend: {SearchSpike.Backend, %{}})

      assert {:ok, literal} = Jido.Shell.Agent.run(session, "grep literal a.b")

      assert SearchSpike.Fixture.normalized(literal) == [
               "./last.txt:1:a.b",
               "./nested/a.txt:1:a.b",
               "./nested/a.txt:3:a.b a.b"
             ]

      assert {:ok, regex} = Jido.Shell.Agent.run(session, "grep regex a.b")

      assert SearchSpike.Fixture.normalized(regex) == [
               "./last.txt:1:a.b",
               "./nested/a.txt:1:a.b",
               "./nested/a.txt:2:aXb",
               "./nested/a.txt:3:a.b a.b"
             ]

      assert {:ok, ""} = Jido.Shell.Agent.run(session, "grep literal missing")
      assert {:ok, empty_line} = Jido.Shell.Agent.run(session, "grep regex ^$")
      assert empty_line == "./nested/a.txt:4:\n"
      assert {:error, _} = Jido.Shell.Agent.run(session, "grep regex [")
    after
      Workspace.close(workspace)
    end
  end
end
