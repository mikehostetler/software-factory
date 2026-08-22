defmodule Hancho.DemandResolverTest do
  use ExUnit.Case, async: true

  alias Hancho.Beadwork.Issue, as: BeadworkIssue
  alias Hancho.Actions
  alias Hancho.Demand.{Resolver, Snapshot}
  alias Hancho.GitHub.Issue, as: GitHubIssue

  defmodule GitHub do
    def fetch(node_id, options) do
      send(self(), {:github_fetch, node_id, options})

      case Process.get(:github_result) do
        nil -> {:error, :not_configured}
        result -> result
      end
    end
  end

  defmodule Beadwork do
    def show("bw-parent", options) do
      send(self(), {:beadwork_parent, options})

      {:ok,
       %{
         "id" => "bw-parent",
         "title" => "Parent",
         "type" => "epic",
         "status" => "open",
         "description" =>
           "Hancho-GitHub-Issue: https://github.test/owner/repo/issues/10\nHancho-GitHub-Node: parent-node"
       }}
    end
  end

  defmodule PreflightGit do
    def status(_options), do: {:ok, %Git.Status{branch: "main", entries: []}}
    def head(_options), do: {:ok, "abc123"}
  end

  defmodule PreflightBeadwork do
    def show("bw-task", _options), do: {:ok, Process.get(:beadwork_task)}
    def show("bw-parent", options), do: Beadwork.show("bw-parent", options)
  end

  setup do
    {:ok, task} =
      BeadworkIssue.new(%{
        id: "bw-task",
        title: "Copied title",
        type: "task",
        status: "open",
        parent: "bw-parent",
        description:
          "Managed execution record for GitHub demand.\n\nHancho-GitHub-Sub-Issue: https://github.test/owner/repo/issues/11\nHancho-GitHub-Node: task-node"
      })

    {:ok, github} =
      GitHubIssue.new(%{
        repository: "owner/repo",
        node_id: "task-node",
        number: 11,
        title: "Authoritative title",
        url: "https://github.test/owner/repo/issues/11",
        state: "open",
        body: "## Scope\n\nImplement the full demand.\n\n## Allowed Scope\n- `lib/hancho/`",
        updated_at: "2026-08-22T12:34:56Z",
        parent_node_id: "parent-node",
        comments: ["Hancho-Beadwork-Task: bw-task"]
      })

    Process.put(:github_result, {:ok, github})
    Process.put(:beadwork_task, BeadworkIssue.to_map(task))
    %{task: task, github: github}
  end

  test "returns an exact content-hashed GitHub snapshot without network code", %{task: task} do
    assert {:ok, snapshot} =
             Resolver.resolve(task, "/repo", github: GitHub, beadwork: Beadwork)

    assert snapshot.source == "github"
    assert snapshot.repository == "owner/repo"
    assert snapshot.url == "https://github.test/owner/repo/issues/11"
    assert snapshot.node_id == "task-node"
    assert snapshot.title == "Authoritative title"
    assert snapshot.body =~ "Implement the full demand"
    assert snapshot.updated_at == "2026-08-22T12:34:56Z"
    assert byte_size(snapshot.content_sha256) == 64
    assert snapshot == Snapshot.from_github(elem(Process.get(:github_result), 1))
    assert_received {:github_fetch, "task-node", [working_dir: "/repo"]}
    assert_received {:beadwork_parent, [working_dir: "/repo"]}
  end

  test "fails when the authoritative issue does not match the Beadwork URL", %{
    task: task,
    github: github
  } do
    Process.put(:github_result, {:ok, %{github | url: "https://github.test/wrong"}})

    assert {:error, message} =
             Resolver.resolve(task, "/repo", github: GitHub, beadwork: Beadwork)

    assert message =~ "did not match the Beadwork mapping"
    assert message =~ "url_mismatch"
  end

  test "fails closed when GitHub cannot load the mapped demand", %{task: task} do
    Process.put(:github_result, {:error, :offline})

    assert {:error, message} =
             Resolver.resolve(task, "/repo", github: GitHub, beadwork: Beadwork)

    assert message =~ "offline"
  end

  test "preflight persists the authoritative view before later actions can run" do
    assert {:ok, result} =
             Actions.Preflight.run(
               %{repo_path: "/repo", issue_id: "bw-task"},
               %{
                 services: %{
                   git: PreflightGit,
                   beadwork: PreflightBeadwork,
                   github: GitHub
                 },
                 log: :disabled
               }
             )

    assert result.demand["source"] == "github"
    assert result.demand["body"] =~ "Implement the full demand"
    assert result.issue["title"] == "Authoritative title"
    refute result.issue["description"] =~ "Managed execution record"
  end
end
