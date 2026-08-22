defmodule Hancho.Actions.Preflight do
  @moduledoc "Checks that one Beadwork task and its repository are ready."

  use Jido.Action,
    name: "hancho_preflight",
    description: "Checks repository and Beadwork task state",
    schema:
      Zoi.object(%{
        repo_path: Zoi.string() |> Zoi.min(1),
        issue_id: Zoi.string() |> Zoi.min(1)
      })

  alias Hancho.Actions.Context
  alias Hancho.Demand.{Resolver, Snapshot}

  @impl true
  def run(%{repo_path: repository, issue_id: issue_id}, context) do
    git = Context.service(context, :git, Hancho.Git)
    beadwork = Context.service(context, :beadwork, Hancho.Beadwork)
    github = Context.service(context, :github, Hancho.GitHub)

    with {:ok, status} <- git.status(working_dir: repository),
         :ok <- clean(status),
         :ok <- attached(status),
         {:ok, baseline} <- git.head(working_dir: repository),
         {:ok, issue} <- beadwork.show(issue_id, working_dir: repository),
         :ok <- ready_issue(issue, beadwork, repository),
         {:ok, demand} <-
           Resolver.resolve(issue, repository, beadwork: beadwork, github: github),
         :ok <- audit_demand(context, demand) do
      demand = Snapshot.to_map(demand)

      {:ok,
       %{
         repo_path: repository,
         issue_id: issue_id,
         baseline: baseline,
         branch: status.branch,
         issue: authoritative_issue(issue, demand),
         demand: demand
       }}
    end
  end

  defp clean(%Git.Status{entries: []}), do: :ok
  defp clean(_status), do: {:error, "The repository has uncommitted changes."}

  defp attached(%Git.Status{branch: branch}) when branch not in [nil, "HEAD (no branch)"], do: :ok
  defp attached(_status), do: {:error, "The repository is on a detached HEAD."}

  defp ready_issue(%{"type" => "task", "status" => status} = issue, beadwork, repository)
       when status in ["open", "in_progress"] do
    blockers_closed(issue["blocked_by"] || [], beadwork, repository)
  end

  defp ready_issue(%{"type" => type}, _beadwork, _repository) when type != "task",
    do: {:error, "The Beadwork item must have the task type."}

  defp ready_issue(_issue, _beadwork, _repository),
    do: {:error, "The Beadwork task is not ready."}

  defp blockers_closed(blockers, beadwork, repository) do
    Enum.reduce_while(blockers, :ok, fn blocker_id, :ok ->
      case beadwork.show(blocker_id, working_dir: repository) do
        {:ok, %{"status" => "closed"}} -> {:cont, :ok}
        {:ok, _issue} -> {:halt, {:error, "The Beadwork task is blocked by #{blocker_id}."}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp authoritative_issue(issue, demand) do
    issue
    |> Map.put("title", demand["title"])
    |> Map.put("description", demand["body"])
    |> Map.put("demand_snapshot", demand)
  end

  defp audit_demand(context, demand) do
    Hancho.Audit.write(Map.get(context, :log, :disabled), "Authoritative demand snapshot",
      event: "demand.snapshot",
      metadata: Snapshot.to_map(demand)
    )
  end
end
