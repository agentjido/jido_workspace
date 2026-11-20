defmodule Jido.Workspace.Examples.PublishReviewedGit do
  @moduledoc false

  @branch "refs/heads/reviewed"
  @path "report.txt"
  @git_environment [
    {"GIT_DIR", nil},
    {"GIT_WORK_TREE", nil},
    {"GIT_COMMON_DIR", nil},
    {"GIT_OBJECT_DIRECTORY", nil},
    {"GIT_ALTERNATE_OBJECT_DIRECTORIES", nil}
  ]

  def prepare(repo, expected_head, report) do
    with :ok <- require_bare(repo),
         {:ok, ^expected_head} <- head(repo) do
      name = "jido-reviewed-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      scratch = Path.join(System.tmp_dir!(), name)

      with :ok <- File.mkdir(scratch) do
        try do
          prepare_commit(repo, expected_head, report, scratch)
        after
          File.rm_rf!(scratch)
        end
      end
    else
      {:ok, _other} -> {:error, :target_changed}
      {:error, _reason} = error -> error
    end
  end

  def publish(repo, %{base: base, commit: commit}) do
    with :ok <- require_bare(repo) do
      case git(repo, ["update-ref", "--no-deref", "--", @branch, commit, base]) do
        {:ok, _output} -> {:ok, commit}
        {:error, _reason} = error -> check_target(repo, base, error)
      end
    end
  end

  defp prepare_commit(repo, base, report, scratch) do
    file = Path.join(scratch, @path)
    index = Path.join(scratch, "index")

    with :ok <- File.chmod(scratch, 0o700),
         :ok <- File.write(file, report),
         {:ok, blob} <- git(repo, ["hash-object", "-w", "--no-filters", "--", file]),
         {:ok, _} <- git(repo, ["read-tree", base], index),
         {:ok, _} <-
           git(repo, ["update-index", "--add", "--cacheinfo", "100644,#{blob},#{@path}"], index),
         {:ok, tree} <- git(repo, ["write-tree"], index),
         {:ok, commit} <-
           git(repo, ["commit-tree", tree, "-p", base, "-m", "Publish reviewed report"]) do
      {:ok, %{base: base, commit: commit}}
    end
  end

  defp check_target(repo, base, error) do
    case head(repo) do
      {:ok, ^base} -> error
      {:ok, _other} -> {:error, :target_changed}
      {:error, {:git, _, 1, ""}} -> {:error, :target_changed}
      {:error, _reason} -> error
    end
  end

  defp head(repo), do: git(repo, ["rev-parse", "--verify", "--quiet", @branch])

  defp require_bare(repo) do
    case git(repo, ["rev-parse", "--is-bare-repository"]) do
      {:ok, "true"} -> :ok
      {:ok, _other} -> {:error, :bare_repository_required}
      {:error, _reason} = error -> error
    end
  end

  defp git(repo, args, index \\ nil) do
    env = [{"GIT_INDEX_FILE", index} | @git_environment]

    case System.cmd("git", ["--git-dir", Path.expand(repo) | args],
           env: env,
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, status} -> {:error, {:git, hd(args), status, String.trim(output)}}
    end
  end
end
