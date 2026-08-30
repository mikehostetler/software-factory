defmodule Hancho.Actions.RemoveWorktree do
  @moduledoc "Removes the completed factory worktree."

  use Jido.Action,
    name: "hancho_remove_worktree",
    description: "Removes a Hancho-owned Git worktree",
    schema:
      Zoi.object(%{
        repo_path: Zoi.string() |> Zoi.min(1),
        worktree_path: Zoi.string() |> Zoi.min(1)
      })

  alias Hancho.Actions.Context
  alias Hancho.Workflow.Effect

  @impl true
  def run(params, context) do
    git = Context.service(context, :git, Hancho.Git)
    root = Path.expand(Path.join([params.repo_path, ".hancho", "worktrees"]))
    path = Path.expand(params.worktree_path)
    relative = Path.relative_to(path, root)

    case Path.safe_relative(relative, root) do
      {:ok, relative} when relative != "." ->
        receipt = %{worktree_path: path, removed: true}

        Effect.run(
          context,
          "remove",
          "git.worktree.remove",
          %{repository: params.repo_path, path: path},
          fn -> reconcile(git, params.repo_path, path, receipt) end,
          fn -> remove(git, params.repo_path, path, receipt) end
        )

      _other ->
        {:error, "Hancho refused to remove a path outside its worktree folder."}
    end
  end

  defp remove(git, repository, path, receipt) do
    with {:ok, :done} <- git.remove_worktree(repository, path),
         {:ok, ^receipt} <- reconcile(git, repository, path, receipt) do
      {:ok, receipt}
    end
  end

  defp reconcile(git, repository, path, receipt) do
    if File.exists?(path) do
      :not_applied
    else
      with {:ok, registrations} <- git.worktrees(working_dir: repository) do
        if Enum.any?(registrations, &same_path?(&1.path, path)) do
          {:error,
           %{
             code: "filesystem_out_of_sync",
             field: "worktree_registration",
             expected: nil,
             actual: path,
             path: path
           }}
        else
          {:ok, receipt}
        end
      end
    end
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
end
