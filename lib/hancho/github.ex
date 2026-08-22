defmodule Hancho.GitHub do
  @moduledoc "Read and comment boundary for GitHub Issues and sub-issues."

  alias Hancho.Command.Result
  alias Hancho.GitHub.Issue

  @query """
  query($owner: String!, $name: String!) {
    repository(owner: $owner, name: $name) {
      nameWithOwner
      issues(first: 100, states: OPEN, orderBy: {field: CREATED_AT, direction: ASC}) {
        pageInfo { hasNextPage }
        nodes {
          id
          number
          title
          url
          state
          body
          updatedAt
          parent { id }
          subIssues { totalCount }
          comments(first: 100) {
            pageInfo { hasNextPage }
            nodes { body }
          }
        }
      }
    }
  }
  """

  @node_query """
  query($id: ID!) {
    node(id: $id) {
      ... on Issue {
        id
        number
        title
        url
        state
        body
        updatedAt
        repository { nameWithOwner }
        parent { id }
        subIssues { totalCount }
        comments(first: 100) {
          pageInfo { hasNextPage }
          nodes { body }
        }
      }
    }
  }
  """

  @spec executable() :: {:ok, String.t()} | {:error, :not_found}
  def executable do
    case System.find_executable("gh") do
      nil -> {:error, :not_found}
      path -> {:ok, path}
    end
  end

  @spec list_open(keyword()) ::
          {:ok, %{repository: String.t(), issues: [Issue.t()]}} | {:error, term()}
  def list_open(options \\ []) do
    with {:ok, %{"nameWithOwner" => repository}} <-
           run_json(["repo", "view", "--json", "nameWithOwner"], options),
         [owner, name] <- String.split(repository, "/", parts: 2),
         {:ok, response} <-
           run_json(
             [
               "api",
               "graphql",
               "-f",
               "query=#{@query}",
               "-F",
               "owner=#{owner}",
               "-F",
               "name=#{name}"
             ],
             options
           ),
         {:ok, values} <- extract_issue_values(response),
         {:ok, issues} <- parse_issues(repository, values) do
      {:ok, %{repository: repository, issues: issues}}
    else
      [_only] -> {:error, :invalid_repository_identity}
      {:error, reason} -> {:error, reason}
      value -> {:error, {:invalid_github_result, value}}
    end
  end

  @spec fetch(String.t(), keyword()) :: {:ok, Issue.t()} | {:error, term()}
  def fetch(node_id, options \\ []) do
    with {:ok, %{"nameWithOwner" => expected_repository}} <-
           run_json(["repo", "view", "--json", "nameWithOwner"], options),
         {:ok, response} <-
           run_json(
             ["api", "graphql", "-f", "query=#{@node_query}", "-F", "id=#{node_id}"],
             options
           ),
         {:ok, value} <- extract_node_value(response),
         repository when is_binary(repository) <- get_in(value, ["repository", "nameWithOwner"]),
         :ok <- same_repository(repository, expected_repository),
         {:ok, [issue]} <- parse_issues(repository, [value]) do
      {:ok, issue}
    else
      nil -> {:error, :github_issue_not_found}
      {:error, reason} -> {:error, reason}
      value -> {:error, {:invalid_github_result, value}}
    end
  end

  @spec comment(Issue.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def comment(%Issue{} = issue, body, options \\ []) do
    run_json(
      ["api", "repos/#{issue.repository}/issues/#{issue.number}/comments", "-f", "body=#{body}"],
      options
    )
  end

  defp extract_issue_values(%{
         "data" => %{
           "repository" => %{
             "issues" => %{"pageInfo" => %{"hasNextPage" => false}, "nodes" => nodes}
           }
         }
       })
       when is_list(nodes) do
    if Enum.any?(nodes, &get_in(&1, ["comments", "pageInfo", "hasNextPage"])) do
      {:error, :github_comment_limit_exceeded}
    else
      {:ok, nodes}
    end
  end

  defp extract_issue_values(%{
         "data" => %{
           "repository" => %{
             "issues" => %{"pageInfo" => %{"hasNextPage" => true}}
           }
         }
       }),
       do: {:error, :github_issue_limit_exceeded}

  defp extract_issue_values(%{"errors" => errors}), do: {:error, {:github_graphql, errors}}
  defp extract_issue_values(value), do: {:error, {:invalid_github_issues, value}}

  defp extract_node_value(%{"data" => %{"node" => nil}}), do: {:error, :github_issue_not_found}

  defp extract_node_value(%{"data" => %{"node" => value}}) when is_map(value) do
    if get_in(value, ["comments", "pageInfo", "hasNextPage"]) do
      {:error, :github_comment_limit_exceeded}
    else
      {:ok, value}
    end
  end

  defp extract_node_value(%{"errors" => errors}), do: {:error, {:github_graphql, errors}}
  defp extract_node_value(value), do: {:error, {:invalid_github_issue, value}}

  defp parse_issues(repository, values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, issues} ->
      attributes = %{
        repository: repository,
        node_id: value["id"],
        number: value["number"],
        title: value["title"],
        url: value["url"],
        state: String.downcase(value["state"] || ""),
        body: value["body"],
        updated_at: value["updatedAt"],
        parent_node_id: get_in(value, ["parent", "id"]),
        comments: Enum.map(get_in(value, ["comments", "nodes"]) || [], &(&1["body"] || "")),
        child_count: get_in(value, ["subIssues", "totalCount"]) || 0
      }

      case Issue.new(attributes) do
        {:ok, issue} -> {:cont, {:ok, [issue | issues]}}
        {:error, reason} -> {:halt, {:error, {:invalid_github_issue, reason}}}
      end
    end)
    |> case do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      error -> error
    end
  end

  defp same_repository(repository, repository), do: :ok

  defp same_repository(actual, expected),
    do: {:error, {:github_repository_mismatch, expected, actual}}

  defp run_json(arguments, options) do
    with {:ok, output} <- run(arguments, options),
         {:ok, value} <- Jason.decode(output) do
      {:ok, value}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, {:invalid_json, Exception.message(error)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run(arguments, options) do
    command = Keyword.get(options, :command, Hancho.Command)
    cwd = Keyword.get(options, :working_dir, File.cwd!())

    with {:ok, executable} <- resolve_executable(options),
         {:ok, %Result{stdout: output, exit_status: 0}} <-
           command.run(executable, arguments, cwd: cwd, stderr_to_stdout: true) do
      {:ok, String.trim(output)}
    else
      {:ok, %Result{stdout: output, exit_status: status}} ->
        {:error, {String.trim(output), status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_executable(options) do
    case Keyword.fetch(options, :executable) do
      {:ok, executable} -> {:ok, executable}
      :error -> executable()
    end
  end
end
