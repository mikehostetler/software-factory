defmodule Hancho.Actions.Land do
  @moduledoc "Fast-forwards the original branch to the verified commit."

  use Jido.Action,
    name: "hancho_land",
    description: "Lands the implementation with a fast-forward merge",
    schema:
      Zoi.object(%{
        repo_path: Zoi.string() |> Zoi.min(1),
        branch: Zoi.string() |> Zoi.min(1) |> Zoi.optional(),
        baseline: Zoi.string() |> Zoi.min(1),
        commit: Zoi.string() |> Zoi.min(1)
      })

  alias Hancho.Actions.Context
  alias Hancho.Workflow.Effect

  @impl true
  def run(params, context) do
    git = Context.service(context, :git, Hancho.Git)

    with {:ok, branch} <- landing_branch(params, context) do
      params = Map.put(params, :branch, branch)

      intent = %{
        repository: params.repo_path,
        branch: branch,
        baseline: params.baseline,
        commit: params.commit
      }

      Effect.run(
        context,
        "land",
        "git.fast_forward",
        intent,
        fn -> reconcile(git, params) end,
        fn -> land(git, params) end
      )
    end
  end

  defp landing_branch(params, context) do
    branch = Map.get(params, :branch) || get_in(context, [:artifacts, "repository", "branch"])

    if is_binary(branch) and branch != "",
      do: {:ok, branch},
      else: {:error, "The landing branch is not available from the workflow or preflight state."}
  end

  defp reconcile(git, params) do
    with {:ok, status} <- git.status(working_dir: params.repo_path),
         :ok <- expected_branch(status, params.branch),
         :ok <- clean(status),
         {:ok, head} <- git.head(working_dir: params.repo_path) do
      cond do
        head == params.commit -> {:ok, %{commit: head, branch: params.branch}}
        head == params.baseline -> :not_applied
        true -> {:error, "The landing branch changed during recovery."}
      end
    end
  end

  defp land(git, params) do
    with {:ok, status} <- git.status(working_dir: params.repo_path),
         :ok <- expected_branch(status, params.branch),
         :ok <- clean(status),
         {:ok, head} <- git.head(working_dir: params.repo_path),
         :ok <- same_baseline(head, params.baseline),
         {:ok, _result} <- git.merge_ff_only(params.repo_path, params.commit),
         {:ok, final_status} <- git.status(working_dir: params.repo_path),
         :ok <- expected_branch(final_status, params.branch),
         :ok <- clean(final_status),
         {:ok, landed} <- git.head(working_dir: params.repo_path),
         :ok <- exact_commit(landed, params.commit) do
      {:ok, %{commit: landed, branch: params.branch}}
    end
  end

  defp clean(%Git.Status{entries: []}), do: :ok
  defp clean(_status), do: {:error, "The landing worktree has uncommitted changes."}

  defp same_baseline(head, head), do: :ok
  defp same_baseline(_head, _baseline), do: {:error, "The landing branch changed during the run."}

  defp exact_commit(commit, commit), do: :ok

  defp exact_commit(actual, expected),
    do:
      {:error,
       %{
         code: "filesystem_out_of_sync",
         field: "landing_head",
         expected: expected,
         actual: actual
       }}

  defp expected_branch(%Git.Status{branch: branch}, branch), do: :ok

  defp expected_branch(%Git.Status{branch: actual}, expected),
    do: {:error, "The landing branch changed from #{expected} to #{actual}."}
end
