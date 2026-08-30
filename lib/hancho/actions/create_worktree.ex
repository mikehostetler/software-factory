defmodule Hancho.Actions.CreateWorktree do
  @moduledoc "Creates a detached worktree for one factory run."

  use Jido.Action,
    name: "hancho_create_worktree",
    description: "Creates an isolated Git worktree",
    schema:
      Zoi.object(%{
        repo_path: Zoi.string() |> Zoi.min(1),
        baseline: Zoi.string() |> Zoi.min(1),
        run_id: Zoi.string() |> Zoi.min(1)
      })

  alias Hancho.Actions.Context
  alias Hancho.Workflow.Effect

  @impl true
  def run(%{repo_path: repository, baseline: baseline, run_id: run_id}, context) do
    git = Context.service(context, :git, Hancho.Git)

    if Regex.match?(~r/^[A-Za-z0-9_-]+$/, run_id) do
      path = Path.join([repository, ".hancho", "worktrees", run_id])
      receipt = %{worktree_path: path, baseline: baseline}

      Effect.run(
        context,
        "create",
        "git.worktree.create",
        %{repository: repository, path: path, baseline: baseline},
        fn -> reconcile(git, repository, path, baseline, receipt) end,
        fn -> create(git, repository, path, baseline, receipt) end
      )
    else
      {:error, "The workflow run ID is not safe for a path."}
    end
  end

  defp reconcile(git, repository, path, baseline, receipt) do
    with {:ok, registrations} <- git.worktrees(working_dir: repository),
         registration = find_registration(registrations, path) do
      case {File.dir?(path), registration} do
        {false, nil} -> :not_applied
        {false, _registration} -> mismatch("worktree_directory", true, false, path)
        {true, nil} -> mismatch("worktree_registration", path, nil, path)
        {true, registration} -> validate_worktree(git, registration, path, baseline, receipt)
      end
    end
  end

  defp create(git, repository, path, baseline, receipt) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, :done} <- git.create_worktree(repository, path, baseline),
         {:ok, ^receipt} <- reconcile(git, repository, path, baseline, receipt) do
      {:ok, receipt}
    end
  end

  defp validate_worktree(git, registration, path, baseline, receipt) do
    with :ok <- equal("worktree_detached", true, registration.detached, path),
         :ok <- equal("worktree_head", baseline, registration.head, path),
         {:ok, status} <- git.status(working_dir: path),
         :ok <- detached_status(status, path),
         {:ok, head} <- git.head(working_dir: path),
         :ok <- equal("worktree_head", baseline, head, path) do
      {:ok, receipt}
    end
  end

  defp detached_status(%Git.Status{branch: branch}, _path)
       when branch in [nil, "HEAD (no branch)"],
       do: :ok

  defp detached_status(%Git.Status{branch: branch}, path),
    do: mismatch("worktree_branch", "detached HEAD", branch, path)

  defp find_registration(registrations, path) do
    Enum.find(registrations, &same_path?(&1.path, path))
  end

  defp same_path?(left, right) do
    Path.expand(left) == Path.expand(right) or same_file?(left, right) or
      (Path.basename(left) == Path.basename(right) and
         same_file?(Path.dirname(left), Path.dirname(right)))
  end

  defp same_file?(left, right) do
    with {:ok, left_stat} <- File.stat(left),
         {:ok, right_stat} <- File.stat(right) do
      left_stat.inode == right_stat.inode and
        left_stat.major_device == right_stat.major_device and
        left_stat.minor_device == right_stat.minor_device
    else
      _error -> false
    end
  end

  defp equal(_field, value, value, _path), do: :ok
  defp equal(field, expected, actual, path), do: mismatch(field, expected, actual, path)

  defp mismatch(field, expected, actual, path) do
    {:error,
     %{
       code: "filesystem_out_of_sync",
       field: field,
       expected: expected,
       actual: Hancho.Log.Event.normalize(actual),
       path: Path.expand(path)
     }}
  end
end
