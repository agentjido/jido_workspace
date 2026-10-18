defmodule Jido.Workspace.Sandbox.OTP do
  @moduledoc false
  alias Jido.Workspace.Sandbox.Files

  def prepare(base, relative, version, initialize) do
    with true <- is_binary(version) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/, version),
         {:ok, root} <- Files.path(base, relative),
         {:ok, rel, apps} <- release(root, version),
         :ok <- initialize(root, rel, apps, initialize) do
      {:ok, %{rel: rel, apps: apps, args: boot_args(root, version)}}
    else
      false -> {:error, :invalid_release_version}
      error -> error
    end
  end

  defp initialize(_, _, _, false), do: :ok

  defp initialize(root, rel, apps, true) do
    :release_handler.create_RELEASES(
      String.to_charlist(root),
      String.to_charlist(Path.join(root, "releases")),
      String.to_charlist(rel),
      apps
    )
  end

  defp boot_args(root, version) do
    ebin = :code.which(:jido_workspace_deploy_target) |> List.to_string() |> Path.dirname()

    [
      "+S",
      "2",
      "-boot",
      Path.join([root, "releases", version, "start"]),
      "-config",
      Path.join([root, "releases", version, "sys"]),
      "-boot_var",
      "DEPLOY_LIB",
      Path.join(root, "lib"),
      "-pa",
      ebin,
      "-sasl",
      "releases_dir",
      Kernel.inspect(Path.join(root, "releases"))
    ]
  end

  defp release(root, version) do
    files = Path.wildcard(Path.join([root, "releases", version, "*.rel"]))
    expected_version = String.to_charlist(version)
    expected_erts = :erlang.system_info(:version)

    with {:ok, _} <- Files.path(root, Path.join("releases", version)),
         [rel] <- files,
         {:ok, _} <- Files.path(root, Path.relative_to(rel, root)),
         {:ok, [{:release, {_, ^expected_version}, {:erts, ^expected_erts}, applications}]} <-
           :file.consult(String.to_charlist(rel)) do
      apps =
        Enum.map(applications, fn entry ->
          app = elem(entry, 0)
          vsn = elem(entry, 1)
          local = Path.join([root, "lib", "#{app}-#{vsn}"])

          parent =
            if File.dir?(local),
              do: Path.join(root, "lib"),
              else: :code.lib_dir(app) |> List.to_string() |> Path.dirname()

          {app, vsn, String.to_charlist(parent)}
        end)

      {:ok, rel, apps}
    else
      other -> {:error, {:invalid_release, other}}
    end
  end
end
