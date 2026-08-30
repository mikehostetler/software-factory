defmodule Hancho.Actions.Commit do
  @moduledoc "Creates the implementation commit in the detached worktree."

  use Jido.Action,
    name: "hancho_commit",
    description: "Commits verified work",
    schema:
      Zoi.object(%{
        worktree_path: Zoi.string() |> Zoi.min(1),
        baseline: Zoi.string() |> Zoi.min(1),
        issue: Zoi.map()
      })

  alias Hancho.Actions.Context
  alias Hancho.Workflow.Effect

  @impl true
  def run(params, context) do
    git = Context.service(context, :git, Hancho.Git)
    issue_id = params.issue["id"] || params.issue[:id]
    title = params.issue["title"] || params.issue[:title] || issue_id

    message = "feat: implement #{issue_id}\n\n#{title}\n\nBeadwork-ID: #{issue_id}"

    Effect.run(
      context,
      "commit",
      "git.commit",
      %{
        worktree_path: params.worktree_path,
        baseline: params.baseline,
        issue_id: issue_id,
        message: message
      },
      fn -> reconcile(git, params.worktree_path, params.baseline, issue_id) end,
      fn -> commit(git, params.worktree_path, params.baseline, issue_id, message) end
    )
  end

  defp reconcile(git, worktree, baseline, issue_id) do
    with {:ok, status} <- git.status(working_dir: worktree),
         :ok <- detached(status),
         {:ok, head} <- git.head(working_dir: worktree) do
      if head == baseline do
        :not_applied
      else
        with :ok <- clean(status),
             {:ok, shown} <- git.show(head, working_dir: worktree),
             :ok <- expected_commit(shown, issue_id) do
          {:ok, %{commit: head, issue_id: issue_id}}
        end
      end
    end
  end

  defp commit(git, worktree, baseline, issue_id, message) do
    with {:ok, status} <- git.status(working_dir: worktree),
         :ok <- detached(status),
         {:ok, head} <- git.head(working_dir: worktree),
         :ok <- unchanged_head(head, baseline),
         :ok <- has_changes(status),
         {:ok, :done} <- git.add_all(worktree),
         {:ok, commit} <- git.commit(worktree, message) do
      {:ok, %{commit: commit.full_hash, issue_id: issue_id}}
    end
  end

  defp clean(%Git.Status{entries: []}), do: :ok
  defp clean(_status), do: {:error, "The recovered commit worktree has new changes."}

  defp detached(%Git.Status{branch: branch}) when branch in [nil, "HEAD (no branch)"], do: :ok

  defp detached(%Git.Status{branch: branch}) do
    {:error,
     %{
       code: "filesystem_out_of_sync",
       field: "worktree_branch",
       expected: "detached HEAD",
       actual: branch
     }}
  end

  defp expected_commit(%Git.ShowResult{commit: commit}, issue_id) when not is_nil(commit) do
    contents = commit.subject <> "\n" <> commit.body

    if String.contains?(contents, "Beadwork-ID: #{issue_id}"),
      do: :ok,
      else: {:error, "The recovered commit does not belong to this Beadwork task."}
  end

  defp expected_commit(_shown, _issue_id), do: {:error, "The recovered commit is invalid."}

  defp unchanged_head(head, head), do: :ok

  defp unchanged_head(_head, _baseline),
    do: {:error, "The coding agent created commits. Hancho requires uncommitted changes."}

  defp has_changes(%Git.Status{entries: []}), do: {:error, "There are no changes to commit."}
  defp has_changes(_status), do: :ok
end
