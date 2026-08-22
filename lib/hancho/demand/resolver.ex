defmodule Hancho.Demand.Resolver do
  @moduledoc "Loads and validates the authoritative demand for one Beadwork task."

  alias Hancho.Beadwork.Issue, as: BeadworkIssue
  alias Hancho.Demand.{Markers, Snapshot}

  @spec resolve(BeadworkIssue.t() | map(), String.t(), keyword()) ::
          {:ok, Snapshot.t()} | {:error, term()}
  def resolve(issue, repository, options \\ []) do
    beadwork = Keyword.get(options, :beadwork, Hancho.Beadwork)
    github = Keyword.get(options, :github, Hancho.GitHub)

    with {:ok, beadwork_issue} <- beadwork_issue(issue),
         urls = Markers.github_urls(beadwork_issue),
         nodes = Markers.github_nodes(beadwork_issue) do
      resolve_markers(urls, nodes, beadwork_issue, beadwork, github, repository)
    end
  end

  defp resolve_markers([], [], issue, _beadwork, _github, _repository),
    do: {:ok, Snapshot.from_beadwork(issue)}

  defp resolve_markers([url], [node_id], issue, beadwork, github, repository) do
    with {:ok, github_issue} <- github.fetch(node_id, working_dir: repository),
         :ok <- mapped_issue(github_issue, issue, url, node_id),
         :ok <- mapped_parent(github_issue, issue, beadwork, repository) do
      {:ok, Snapshot.from_github(github_issue)}
    else
      {:error, reason} -> {:error, demand_error(reason)}
    end
  end

  defp resolve_markers(_urls, _nodes, _issue, _beadwork, _github, _repository) do
    {:error, "The Beadwork demand mapping must contain exactly one GitHub URL and node ID."}
  end

  defp mapped_issue(github_issue, beadwork_issue, url, node_id) do
    backlinks = Markers.beadwork_ids(github_issue)

    cond do
      github_issue.node_id != node_id -> {:error, :node_id_mismatch}
      github_issue.url != url -> {:error, :url_mismatch}
      github_issue.state != "open" -> {:error, :github_demand_not_open}
      is_nil(github_issue.parent_node_id) -> {:error, :github_demand_is_not_sub_issue}
      backlinks != [beadwork_issue.id] -> {:error, :github_backlink_mismatch}
      true -> :ok
    end
  end

  defp mapped_parent(github_issue, beadwork_issue, beadwork, repository) do
    with parent_id when is_binary(parent_id) <- beadwork_issue.parent,
         {:ok, parent} <- beadwork.show(parent_id, working_dir: repository),
         {:ok, parent_issue} <- BeadworkIssue.new(parent),
         [parent_node_id] <- Markers.github_nodes(parent_issue),
         true <- parent_node_id == github_issue.parent_node_id do
      :ok
    else
      _reason -> {:error, :github_parent_mapping_mismatch}
    end
  end

  defp beadwork_issue(%BeadworkIssue{} = issue), do: {:ok, issue}
  defp beadwork_issue(issue), do: BeadworkIssue.new(issue)

  defp demand_error(reason) do
    "The authoritative GitHub demand could not be loaded or did not match the Beadwork mapping: #{inspect(reason)}"
  end
end
