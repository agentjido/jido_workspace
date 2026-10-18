defmodule Jido.Workspace.Deploy.Test.Releases do
  @moduledoc false
  alias Jido.Workspace.Deploy.{Artifact, Snapshot}

  def build(root) do
    File.mkdir_p!(root)

    for {version, factor} <- [{"1", 1}, {"2", 2}, {"3", 3}] do
      ebin = Path.join([root, "lib", "counter_demo-" <> version, "ebin"])
      File.mkdir_p!(ebin)

      for file <- Path.wildcard(Path.expand("../fixtures/counter/*.erl", __DIR__)) do
        {:ok, _} =
          :compile.file(String.to_charlist(file), [
            {:outdir, String.to_charlist(ebin)},
            {:d, :VSN, String.to_charlist(version)},
            {:d, :FACTOR, factor},
            :report_errors,
            :report_warnings
          ])
      end

      app =
        {:application, :counter_demo,
         [
           vsn: String.to_charlist(version),
           description: ~c"Counter release test",
           modules: [:counter_app, :counter_sup, :counter_server],
           registered: [:counter_sup, :counter_server],
           applications: [:kernel, :stdlib],
           mod: {:counter_app, []}
         ]}

      write_term(Path.join(ebin, "counter_demo.app"), app)

      appup =
        {String.to_charlist(version),
         [
           {~c"1", [{:update, :counter_server, {:advanced, []}}]},
           {~c"2", [{:update, :counter_server, {:advanced, []}}]}
         ], [{~c"1", [{:update, :counter_server, {:advanced, []}}]}]}

      write_term(Path.join(ebin, "counter_demo.appup"), appup)
      rel_dir = Path.join([root, "releases", version])
      File.mkdir_p!(rel_dir)

      applications =
        Enum.map([:kernel, :stdlib, :sasl], fn name ->
          {:ok, _} = Application.ensure_all_started(name)
          {:ok, vsn} = :application.get_key(name, :vsn)
          {name, vsn}
        end) ++ [{:counter_demo, String.to_charlist(version)}]

      release =
        {:release, {~c"counter", String.to_charlist(version)},
         {:erts, :erlang.system_info(:version)}, applications}

      basename = Path.join(rel_dir, "counter")
      write_term(basename <> ".rel", release)
      write_term(Path.join(rel_dir, "sys.config"), [])

      options = [
        {:path, [String.to_charlist(ebin)]},
        {:variables, [{~c"DEPLOY_LIB", String.to_charlist(Path.join(root, "lib"))}]},
        :silent
      ]

      {:ok, :systools_make, []} = :systools.make_script(String.to_charlist(basename), options)
      File.cp!(basename <> ".boot", Path.join(rel_dir, "start.boot"))
    end

    for version <- ["2", "3"] do
      paths =
        for v <- [version, "1", "2"] |> Enum.uniq(),
            do: String.to_charlist(Path.join([root, "lib", "counter_demo-" <> v, "ebin"]))

      current = String.to_charlist(Path.join([root, "releases", version, "counter"]))
      previous = String.to_charlist(Path.join([root, "releases", "1", "counter"]))

      from =
        if version == "3",
          do: [previous, String.to_charlist(Path.join([root, "releases", "2", "counter"]))],
          else: [previous]

      {:ok, _, :systools_relup, []} =
        :systools.make_relup(current, from, [previous], [
          {:path, paths},
          {:outdir, String.to_charlist(Path.join([root, "releases", version]))},
          :silent
        ])
    end

    {:ok, full} = Snapshot.from_directory(root)

    Map.new(["1", "2", "3"], fn version ->
      entries =
        Map.filter(full.entries, fn {path, _} ->
          String.starts_with?(path, "lib/counter_demo-" <> version <> "/") or
            String.starts_with?(path, "releases/" <> version <> "/")
        end)

      {:ok, snapshot} = Snapshot.new(entries, id: "counter-source-" <> version)
      {:ok, artifact} = Artifact.new(:otp, version, snapshot)
      {version, artifact}
    end)
  end

  defp write_term(path, term), do: File.write!(path, :io_lib.format(~c"~tp.~n", [term]))
end
