defmodule Hancho.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  defmodule ProjectAPI do
    def discover(cwd: cwd), do: {:ok, Hancho.Project.new(cwd)}
  end

  defmodule WorkflowRunner do
    def run(project, "implement", input, options) do
      send(self(), {:workflow_input, project, input, options[:verbose]})

      Hancho.Workflow.Result.new(%{
        run_id: "run-123",
        workflow: "implement",
        status: :completed,
        current_step: nil,
        outputs: %{},
        error: nil
      })
    end

    def retry(project, "run-stopped", options) do
      send(self(), {:workflow_retry, project, options[:verbose]})

      Hancho.Workflow.Result.new(%{
        run_id: "run-stopped",
        workflow: "implement",
        status: :completed,
        current_step: nil,
        outputs: %{},
        error: nil
      })
    end
  end

  defmodule StoppedWorkflowRunner do
    def run(_project, "implement", _input, _options) do
      Hancho.Workflow.Result.new(%{
        run_id: "run-failed",
        workflow: "implement",
        status: :stopped,
        current_step: "validate_scope",
        outputs: %{},
        error: %{code: "changes_outside_allowed_scope"},
        forensic_report: "/repo/.hancho/forensics/runs/run-failed.json"
      })
    end
  end

  defmodule QueueRunner do
    def run(project, "implement", "beadwork-ready", 5, options) do
      send(self(), {:queue_input, project, options[:verbose]})
      options[:progress].("Queue queue-1 started.")

      Hancho.Workflow.QueueResult.new(%{
        queue_id: "queue-1",
        workflow: "implement",
        status: :completed,
        completed_count: 5,
        total_count: 5,
        current_issue: nil,
        child_runs: ["queue-1-001"],
        error: nil
      })
    end

    def preview(project, "implement", "beadwork-ready", 1, options) do
      send(self(), {:queue_preview, project, options[:verbose]})

      {:ok,
       %{
         workflow: "implement",
         source: "beadwork-ready",
         issues: [%{"id" => "task-1", "title" => "First task", "status" => "open"}],
         repository: %{branch: "main", head: "abc123", clean: true, worktrees: ["retained"]},
         settings: %{
           provider: "grok",
           model: nil,
           reasoning_effort: "xhigh",
           implementation_timeout_ms: 1_800_000,
           verification_timeout_ms: 600_000,
           repairs: [
             %{
               step: "validate_scope",
               provider: "grok",
               max_attempts: 1,
               codes: ["changes_outside_allowed_scope"]
             }
           ]
         }
       }}
    end

    def resume(project, "queue-stopped", options) do
      send(self(), {:queue_resume, project, options[:verbose]})
      options[:progress].("Queue queue-stopped resumed.")

      Hancho.Workflow.QueueResult.new(%{
        queue_id: "queue-stopped",
        workflow: "implement",
        status: :completed,
        completed_count: 1,
        total_count: 1,
        current_issue: nil,
        child_runs: ["queue-stopped-001"],
        error: nil
      })
    end
  end

  defmodule StoppedQueueRunner do
    def run(_project, "implement", "beadwork-ready", 1, _options) do
      Hancho.Workflow.QueueResult.new(%{
        queue_id: "queue-failed",
        workflow: "implement",
        status: :stopped,
        completed_count: 0,
        total_count: 1,
        current_issue: "task-1",
        child_runs: ["queue-failed-001"],
        error: %{code: "workflow_stopped"},
        forensic_report: "/repo/.hancho/forensics/queues/queue-failed.json"
      })
    end
  end

  defmodule MatrixAPI do
    def run(project, prompt, cells, options) do
      send(self(), {:matrix_run, project, prompt, cells, options})

      {:ok,
       %{
         "schema_version" => 1,
         "matrix_run_id" => "matrix-cli",
         "status" => "completed",
         "runs" => []
       }}
    end
  end

  defmodule SummaryQueueRunner do
    def run(_project, "implement", "beadwork-ready", 2, _options) do
      Hancho.Workflow.QueueResult.new(%{
        queue_id: "queue-summary",
        workflow: "implement",
        status: :completed,
        completed_count: 2,
        total_count: 2,
        current_issue: nil,
        child_runs: ["run-1", "run-2"],
        elapsed_ms: 120_000,
        task_summaries: [
          %{
            "issue_id" => "task-1",
            "elapsed_ms" => 60_000,
            "provider" => "codex",
            "model" => "gpt-pinned",
            "usage" => %{
              "status" => "available",
              "scope" => "run",
              "values" => %{"total_tokens" => 12}
            }
          },
          %{
            "issue_id" => "task-2",
            "elapsed_ms" => 60_000,
            "provider" => "grok",
            "model" => nil,
            "usage" => %{
              "status" => "available",
              "scope" => "provider_cumulative",
              "values" => %{"total_tokens" => 99_999}
            }
          }
        ],
        usage_summary: %{
          "status" => "partial",
          "values" => %{"total_tokens" => 12},
          "excluded_task_count" => 1
        },
        error: nil
      })
    end
  end

  defmodule RunInspector do
    def inspect(project, "run-123", _options) do
      send(self(), {:run_inspect, project})

      {:ok,
       %{
         run_id: "run-123",
         workflow: "implement",
         status: "stopped",
         current_step: "verify",
         started_at: "2026-08-17T10:00:00Z",
         finished_at: "2026-08-17T10:01:00Z",
         duration_ms: 60_000,
         provider: %{
           "provider" => "grok",
           "harness_run_id" => "harness-1",
           "status" => "completed"
         },
         verification: nil,
         commit: nil,
         retained_worktree: "/repo/.hancho/worktrees/run-123",
         forensic_report: "/repo/.hancho/forensics/runs/run-123.json",
         failure: "tests failed",
         steps: [
           %{position: 0, name: "implement", status: "completed", duration_ms: 55_000},
           %{position: 1, name: "verify", status: "stopped", duration_ms: 5_000}
         ]
       }}
    end
  end

  defmodule WorktreesAPI do
    def list(project, _options) do
      send(self(), {:worktrees_list, project})

      {:ok,
       [
         %{
           id: "run-retained",
           clean: false,
           size_bytes: 287_000_000
         }
       ]}
    end

    def inspect(project, "run-retained", _options) do
      send(self(), {:worktrees_inspect, project})

      {:ok,
       %{
         id: "run-retained",
         path: "/repo/.hancho/worktrees/run-retained",
         registered: true,
         detached: true,
         head: "abc123",
         clean: false,
         size_bytes: 287_000_000,
         generated_bytes: 285_000_000,
         changed_paths: ["feature.ex"]
       }}
    end

    def clean(project, "run-retained", _options) do
      send(self(), {:worktrees_clean, project})

      {:ok,
       %{
         id: "run-retained",
         removed: ["_build", "deps"],
         reclaimed_bytes: 285_000_000,
         source_changes_retained: true
       }}
    end
  end

  test "has explicit help and version commands" do
    assert capture_io(fn -> assert Hancho.CLI.run([]) == 0 end) =~ "Usage:"
    assert capture_io(fn -> assert Hancho.CLI.run(["--help"]) == 0 end) =~ "hancho doctor"
    assert capture_io(fn -> assert Hancho.CLI.run(["-h"]) == 0 end) =~ "hancho doctor"
    assert capture_io(fn -> assert Hancho.CLI.run(["--version"]) == 0 end) == "0.1.0\n"
    assert capture_io(fn -> assert Hancho.CLI.run(["-v"]) == 0 end) == "0.1.0\n"
    assert capture_io(fn -> assert Hancho.CLI.run(["help"]) == 0 end) =~ "Usage:"
    assert capture_io(fn -> assert Hancho.CLI.run(["version"]) == 0 end) == "0.1.0\n"
  end

  test "parses global options after a command" do
    assert capture_io(fn -> assert Hancho.CLI.run(["doctor", "--help"]) == 0 end) =~ "Usage:"
  end

  test "rejects an unknown command" do
    output = capture_io(:stderr, fn -> assert Hancho.CLI.run(["unknown"]) == 2 end)

    assert output ==
             "ERROR: Unknown command: unknown\nRun 'hancho --help' for usage.\n"
  end

  test "rejects unknown options" do
    output = capture_io(:stderr, fn -> assert Hancho.CLI.run(["--unknown"]) == 2 end)

    assert output ==
             "ERROR: Unknown option: --unknown\nRun 'hancho --help' for usage.\n"
  end

  test "rejects extra command arguments" do
    output = capture_io(:stderr, fn -> assert Hancho.CLI.run(["doctor", "extra"]) == 2 end)

    assert output ==
             "ERROR: Unknown command: doctor extra\nRun 'hancho --help' for usage.\n"
  end

  test "runs one workflow in the foreground" do
    output =
      capture_io(fn ->
        assert Hancho.CLI.run(["run", "implement", "hancho-123"],
                 cwd: "/repo",
                 project_api: ProjectAPI,
                 workflow_runner: WorkflowRunner
               ) == 0
      end)

    assert output == "Workflow implement completed. Run: run-123\n"

    assert_received {:workflow_input, project,
                     %{"repo_path" => "/repo", "issue_id" => "hancho-123"}, false}

    assert project.bedrock_path == "/repo/.hancho/bedrock"
  end

  test "prints the forensic report for a stopped workflow" do
    output =
      capture_io(:stderr, fn ->
        assert Hancho.CLI.run(["run", "implement", "hancho-123"],
                 cwd: "/repo",
                 project_api: ProjectAPI,
                 workflow_runner: StoppedWorkflowRunner
               ) == 1
      end)

    assert output =~ "ERROR: Workflow implement stopped at validate_scope"
    assert output =~ "Forensic report: /repo/.hancho/forensics/runs/run-failed.json\n"
  end

  test "prints the forensic report for a stopped queue" do
    output =
      capture_io(:stderr, fn ->
        assert Hancho.CLI.run(
                 ["queue", "implement", "--source", "beadwork-ready", "--count", "1"],
                 cwd: "/repo",
                 project_api: ProjectAPI,
                 queue_runner: StoppedQueueRunner
               ) == 1
      end)

    assert output =~ "ERROR: Queue queue-failed stopped at task-1"
    assert output =~ "Forensic report: /repo/.hancho/forensics/queues/queue-failed.json\n"
  end

  test "runs one workflow with verbose provider output enabled" do
    output =
      capture_io(fn ->
        assert Hancho.CLI.run(["run", "implement", "hancho-123", "--verbose"],
                 cwd: "/repo",
                 project_api: ProjectAPI,
                 workflow_runner: WorkflowRunner
               ) == 0
      end)

    assert output == "Workflow implement completed. Run: run-123\n"

    assert_received {:workflow_input, _project,
                     %{"repo_path" => "/repo", "issue_id" => "hancho-123"}, true}
  end

  test "inspects durable workflow state" do
    output =
      capture_io(fn ->
        assert Hancho.CLI.run(["run", "inspect", "run-123"],
                 cwd: "/repo",
                 project_api: ProjectAPI,
                 run_inspector: RunInspector
               ) == 0
      end)

    assert output =~ "Run: run-123\n"
    assert output =~ "Status: stopped at verify\n"
    assert output =~ "Provider: grok completed (harness-1)\n"
    assert output =~ "Verification: not started\n"
    assert output =~ "Retained worktree: /repo/.hancho/worktrees/run-123\n"
    assert output =~ "Forensic report: /repo/.hancho/forensics/runs/run-123.json\n"
    assert output =~ "2. verify: stopped (5000 ms)\n"
    assert_received {:run_inspect, project}
    assert project.root == "/repo"
  end

  test "lists, inspects, and cleans retained worktrees" do
    options = [cwd: "/repo", project_api: ProjectAPI, worktrees_api: WorktreesAPI]

    assert capture_io(fn -> assert Hancho.CLI.run(["worktrees", "list"], options) == 0 end) ==
             "run-retained: changed, 287000000 bytes\n"

    inspect_output =
      capture_io(fn ->
        assert Hancho.CLI.run(["worktrees", "inspect", "run-retained"], options) == 0
      end)

    assert inspect_output =~ "Worktree: run-retained\n"
    assert inspect_output =~ "Registered: yes\n"
    assert inspect_output =~ "Generated: 285000000 bytes\n"
    assert inspect_output =~ "- feature.ex\n"

    clean_output =
      capture_io(fn ->
        assert Hancho.CLI.run(["worktrees", "clean", "run-retained"], options) == 0
      end)

    assert clean_output ==
             "Cleaned run-retained: _build, deps\n" <>
               "Reclaimed: 285000000 bytes\n" <>
               "Source changes retained: yes\n"

    assert_received {:worktrees_list, %Hancho.Project{root: "/repo"}}
    assert_received {:worktrees_inspect, %Hancho.Project{root: "/repo"}}
    assert_received {:worktrees_clean, %Hancho.Project{root: "/repo"}}
  end

  test "retries a stopped workflow" do
    output =
      capture_io(fn ->
        assert Hancho.CLI.run(["retry", "run-stopped", "--verbose"],
                 cwd: "/repo",
                 project_api: ProjectAPI,
                 workflow_runner: WorkflowRunner
               ) == 0
      end)

    assert output == "Workflow implement completed. Run: run-stopped\n"
    assert_received {:workflow_retry, project, true}
    assert project.root == "/repo"
  end

  test "resumes a stopped queue" do
    output =
      capture_io(fn ->
        assert Hancho.CLI.run(["resume", "queue-stopped", "--verbose"],
                 cwd: "/repo",
                 project_api: ProjectAPI,
                 queue_runner: QueueRunner
               ) == 0
      end)

    assert output == "Queue queue-stopped resumed.\n"
    assert_received {:queue_resume, project, true}
    assert project.root == "/repo"
  end

  test "runs an explicit foreground queue with verbose progress" do
    output =
      capture_io(fn ->
        assert Hancho.CLI.run(
                 [
                   "queue",
                   "implement",
                   "--source",
                   "beadwork-ready",
                   "--count",
                   "5",
                   "--verbose"
                 ],
                 cwd: "/repo",
                 project_api: ProjectAPI,
                 queue_runner: QueueRunner
               ) == 0
      end)

    assert output == "Queue queue-1 started.\n"
    assert_received {:queue_input, project, true}
    assert project.root == "/repo"
  end

  test "runs a matrix task and prints JSON" do
    output =
      capture_io(fn ->
        assert Hancho.CLI.run(
                 [
                   "matrix-run",
                   "--task",
                   "Test the local cart.",
                   "--cell",
                   "codex=gpt-a",
                   "--cell",
                   "claude=sonnet",
                   "--concurrency",
                   "2",
                   "--max-tokens",
                   "500",
                   "--json"
                 ],
                 cwd: "/repo",
                 project_api: ProjectAPI,
                 matrix_api: MatrixAPI
               ) == 0
      end)

    assert Jason.decode!(output)["matrix_run_id"] == "matrix-cli"

    assert_received {:matrix_run, project, "Test the local cart.",
                     ["codex=gpt-a", "claude=sonnet"], options}

    assert project.root == "/repo"
    assert options[:concurrency] == 2
    assert options[:max_tokens] == 500
  end

  test "requires one matrix task source" do
    output =
      capture_io(:stderr, fn ->
        assert Hancho.CLI.run(["matrix-run", "--cell", "codex=gpt-a"],
                 cwd: "/repo",
                 project_api: ProjectAPI,
                 matrix_api: MatrixAPI
               ) == 2
      end)

    assert output == "ERROR: Matrix run requires --task or --task-file.\n"
  end

  test "prints normalized queue time, model, and usage summaries" do
    output =
      capture_io(fn ->
        assert Hancho.CLI.run(
                 ["queue", "implement", "--source", "beadwork-ready", "--count", "2"],
                 cwd: "/repo",
                 project_api: ProjectAPI,
                 queue_runner: SummaryQueueRunner
               ) == 0
      end)

    assert output =~ "Queue summary: 2/2 tasks, 120000 ms elapsed"
    assert output =~ "task-1: 60000 ms; codex; gpt-pinned; usage run, 12 total tokens"
    assert output =~ "task-2: 60000 ms; grok; provider default; not pinned"
    assert output =~ "1 non-additive task values excluded"
    refute output =~ "100011"
  end

  test "requires explicit queue source and count" do
    output =
      capture_io(:stderr, fn ->
        assert Hancho.CLI.run(["queue", "implement", "--source", "beadwork-ready"]) == 2
      end)

    assert output == "ERROR: queue requires --source and a positive --count.\n"
  end

  test "previews a queue without running it" do
    output =
      capture_io(fn ->
        assert Hancho.CLI.run(
                 [
                   "queue",
                   "implement",
                   "--source",
                   "beadwork-ready",
                   "--count",
                   "1",
                   "--dry-run"
                 ],
                 cwd: "/repo",
                 project_api: ProjectAPI,
                 queue_runner: QueueRunner
               ) == 0
      end)

    assert output ==
             "Dry run: implement selected 1 task from beadwork-ready.\n" <>
               "Repository: main at abc123 (clean)\n" <>
               "Retained worktrees: 1\n" <>
               "Provider: grok\n" <>
               "Model: not configured (provider default; not pinned)\n" <>
               "Reasoning effort: xhigh\n" <>
               "Timeouts: implement 1800000 ms, verify 600000 ms\n" <>
               "Repair: validate_scope via grok, 1 attempt (changes_outside_allowed_scope)\n" <>
               "1. task-1 — First task\n"

    assert_received {:queue_preview, project, false}
    assert project.root == "/repo"
    refute_received {:queue_input, _project, _verbose}
  end
end
