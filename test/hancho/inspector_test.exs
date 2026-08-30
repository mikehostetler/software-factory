defmodule Hancho.InspectorTest do
  use ExUnit.Case, async: true

  alias Hancho.Workflow.Inspector

  defmodule Store do
    def open(_path), do: {:ok, :memory}

    def flush(:memory) do
      send(self(), :store_flushed)
      :ok
    end

    def fetch_run(:memory, "run-inspect") do
      outputs = %{
        "workspace_opened" => %{"worktree_path" => "/repo/.hancho/worktrees/run-inspect"},
        "agent_call" => %{
          "provider" => "grok",
          "harness_run_id" => "harness-1",
          "status" => "completed",
          "text" => "implemented"
        },
        "test_suite" => %{
          "exit_status" => 0,
          "output" => "Finished in 1 second\nResult: 12 passed\n",
          "output_path" => "/repo/.hancho/logs/run-inspect-verify.log"
        },
        "saved_change" => %{"commit" => "abc123"}
      }

      {:ok,
       %{
         "id" => "run-inspect",
         "workflow_name" => "implement",
         "status" => "stopped",
         "current_step" => "publish",
         "started_at" => "2026-08-17T10:00:00Z",
         "finished_at" => "2026-08-17T10:02:00Z",
         "error_json" => Jason.encode!(%{"message" => "branch changed"}),
         "outputs_json" => Jason.encode!(outputs)
       }}
    end

    def list_steps(:memory, "run-inspect") do
      {:ok,
       [
         step(0, "workspace_opened", "completed", "2026-08-17T10:00:00Z", "2026-08-17T10:00:10Z"),
         step(1, "agent_call", "completed", "2026-08-17T10:00:10Z", "2026-08-17T10:01:30Z"),
         step(2, "test_suite", "completed", "2026-08-17T10:01:30Z", "2026-08-17T10:01:45Z"),
         step(3, "saved_change", "completed", "2026-08-17T10:01:45Z", "2026-08-17T10:01:45Z"),
         step(4, "publish", "stopped", "2026-08-17T10:01:45Z", "2026-08-17T10:02:00Z")
       ]}
    end

    defp step(position, name, status, started_at, finished_at) do
      %{
        "position" => position,
        "name" => name,
        "action" => action(name),
        "status" => status,
        "started_at" => started_at,
        "finished_at" => finished_at,
        "error_json" => if(status == "stopped", do: Jason.encode!("branch changed"), else: nil)
      }
    end

    defp action("workspace_opened"), do: "Hancho.Actions.CreateWorktree"
    defp action("agent_call"), do: "Hancho.Actions.Implement"
    defp action("test_suite"), do: "Hancho.Actions.Verify"
    defp action("saved_change"), do: "Hancho.Actions.Commit"
    defp action("publish"), do: "Hancho.Actions.Land"
  end

  defmodule FailureStore do
    def open(_path), do: {:ok, :memory}

    def fetch_run(:memory, "run-provider-failed") do
      {:ok,
       %{
         "id" => "run-provider-failed",
         "workflow_name" => "implement",
         "status" => "stopped",
         "current_step" => "implement",
         "started_at" => "2026-08-17T10:00:00Z",
         "finished_at" => "2026-08-17T10:00:05Z",
         "error_json" => Jason.encode!(%{"code" => "provider_failed"}),
         "outputs_json" => "{}"
       }}
    end

    def list_steps(:memory, "run-provider-failed") do
      {:ok,
       [
         %{
           "position" => 0,
           "name" => "implement",
           "action" => "Hancho.Actions.Implement",
           "status" => "stopped",
           "started_at" => "2026-08-17T10:00:00Z",
           "finished_at" => "2026-08-17T10:00:05Z",
           "operation_json" =>
             Jason.encode!(%{
               kind: "jido_harness.run",
               id: "harness-failed",
               metadata: %{
                 provider: "codex",
                 terminal_status: "failed",
                 error: "expired credentials"
               },
               history: [%{kind: "jido_harness.run", id: "harness-prior", metadata: %{}}]
             }),
           "repairs_json" => "[]",
           "error_json" => Jason.encode!(%{"code" => "provider_failed"})
         }
       ]}
    end

    def list_effects(:memory, "run-provider-failed") do
      {:ok,
       [
         %{
           "step_position" => 0,
           "key" => "create",
           "kind" => "git.worktree.create",
           "status" => "intended",
           "attempt" => 1,
           "started_at" => "2026-08-17T10:00:01Z",
           "applied_at" => nil,
           "intent_json" => Jason.encode!(%{"path" => "/repo/.hancho/worktrees/run"}),
           "receipt_json" => nil,
           "error_json" => nil
         }
       ]}
    end
  end

  test "reports durable timings, agent output, verification, and retained work" do
    project = Hancho.Project.new("/repo")

    assert {:ok, report} = Inspector.inspect(project, "run-inspect", store_api: Store)
    assert report.status == "stopped"
    assert report.current_step == "publish"
    assert report.duration_ms == 120_000
    assert report.provider["provider"] == "grok"
    assert report.provider["harness_run_id"] == "harness-1"
    assert report.verification.summary == "Result: 12 passed"
    assert report.verification.exit_status == 0
    assert report.commit == "abc123"
    assert report.retained_worktree == "/repo/.hancho/worktrees/run-inspect"
    assert report.forensic_report == nil
    assert report.failure == %{"message" => "branch changed"}
    assert Enum.map(report.steps, & &1.duration_ms) == [10_000, 80_000, 15_000, 0, 15_000]
    assert List.last(report.steps).error == "branch changed"
    refute_received :store_flushed
  end

  test "reports failed provider and external-effect evidence without step output" do
    project = Hancho.Project.new("/repo")

    assert {:ok, report} =
             Inspector.inspect(project, "run-provider-failed", store_api: FailureStore)

    assert report.provider["harness_run_id"] == "harness-failed"
    assert report.provider["provider"] == "codex"
    assert report.provider["status"] == "failed"
    assert report.provider["error"] == "expired credentials"
    assert [%{"id" => "harness-prior"}] = report.provider["history"]

    assert [effect] = report.effects
    assert effect["status"] == "intended"
    assert effect["intent"] == %{"path" => "/repo/.hancho/worktrees/run"}
    assert hd(report.steps).operation["id"] == "harness-failed"
  end
end
