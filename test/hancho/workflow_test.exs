defmodule Hancho.WorkflowTest do
  use ExUnit.Case, async: false

  alias Hancho.Workflow.{Definition, Loader, Params, Runner, Store}

  defmodule Beadwork do
    def show(issue_id, _options), do: {:ok, issue(issue_id, "open")}
    def start(issue_id, _options), do: {:ok, issue(issue_id, "in_progress")}
    def comment(issue_id, _text, _options), do: {:ok, %{"id" => issue_id}}
    def close(issue_id, _options), do: {:ok, issue(issue_id, "closed")}
    def sync(_options), do: {:ok, "synced"}

    defp issue(issue_id, status) do
      %{
        "id" => issue_id,
        "title" => "Add an implementation file",
        "description" => "Create implemented.txt",
        "type" => "task",
        "status" => status,
        "blocked_by" => []
      }
    end
  end

  defmodule Harness do
    def run(:codex, _prompt, options) do
      File.write!(Path.join(options[:cwd], "implemented.txt"), "implemented\n")

      {:ok,
       Jido.Harness.RunResult.new!(%{
         run_id: "agent-run",
         provider: :codex,
         status: :completed,
         text: "done"
       })}
    end
  end

  defmodule Command do
    def run(_executable, ["test"], _options) do
      {:ok, %Hancho.Command.Result{stdout: "tests passed\n", stderr: "", exit_status: 0}}
    end
  end

  defmodule Registry do
    def fetch("Test.First"), do: {:ok, :first}
    def fetch("Test.Second"), do: {:ok, :second}
    def fetch(name), do: {:error, "Unknown test action: #{name}"}
  end

  defmodule Executor do
    def run(:first, %{"value" => value}, _context), do: {:ok, %{value: value + 1}}
    def run(:second, %{"value" => value}, _context), do: {:ok, %{value: value * 2}}
  end

  defmodule ContextExecutor do
    def run(:first, %{"value" => value}, context) do
      send(context.services.test_pid, {:action_verbose, context.verbose})
      {:ok, %{value: value + 1}}
    end

    def run(:second, %{"value" => value}, _context), do: {:ok, %{value: value * 2}}
  end

  defmodule MissingOutputExecutor do
    def run(:first, %{"value" => value}, _context), do: {:ok, %{other: value}}
  end

  defmodule TransientExecutor do
    def run(:first, %{"value" => value}, context) do
      send(context.services.test_pid, :first_executed)
      Process.put(__MODULE__, true)
      {:ok, %{value: value + 1}}
    end

    def run(:second, %{"value" => value}, context) do
      send(context.services.test_pid, :second_executed)

      if Process.get(__MODULE__) do
        Process.delete(__MODULE__)
        {:error, :transient_failure}
      else
        {:ok, %{value: value * 2}}
      end
    end
  end

  defmodule RetryReconciler do
    def retry(_project, outputs, _options) do
      send(self(), {:retry_reconciled, outputs})
      {:ok, %{clean: true}}
    end
  end

  defmodule FailingRetryReconciler do
    def retry(_project, _outputs, _options) do
      {:error,
       %{
         code: "filesystem_out_of_sync",
         field: "repository_status",
         expected: "clean",
         actual: [%{path: "unexpected.txt"}]
       }}
    end
  end

  defmodule RecordingFailureCleanup do
    def run(project, result, options) do
      send(options[:test_pid], {:failure_cleanup, project.root, result.current_step})
      %{status: "completed", removed: ["_build", "deps"]}
    end
  end

  defmodule RepairRegistry do
    def fetch("Hancho.Actions.UseRepository"), do: {:ok, :workspace}
    def fetch("Hancho.Actions.ValidateScope"), do: {:ok, :scope_gate}
  end

  defmodule RepairExecutor do
    def run(:workspace, %{"repo_path" => path}, _context) do
      {:ok, %{mode: "in_place", workspace_path: path, baseline: "head-0"}}
    end

    def run(:scope_gate, %{"worktree_path" => path}, _context) do
      if File.exists?(Path.join(path, "repair-complete")) do
        {:ok, %{status: "checked", allowed_scope: ["lib/"], changed_paths: ["lib/ok.ex"]}}
      else
        {:error,
         %{
           code: "changes_outside_allowed_scope",
           allowed_scope: ["lib/"],
           unexpected_paths: ["notes.txt"]
         }}
      end
    end

    def run(Hancho.Actions.Implement, params, context) do
      send(context.services.test_pid, {:repair_prompt, params.prompt, context.activity})
      File.write!(Path.join(params.worktree_path, "repair-complete"), "repaired\n")

      {:ok,
       %{
         provider: params.provider,
         harness_run_id: "repair-harness-1",
         status: "completed",
         text: "repaired",
         text_truncated: false
       }}
    end
  end

  defmodule ExhaustedRepairExecutor do
    def run(:workspace, params, context), do: RepairExecutor.run(:workspace, params, context)

    def run(:scope_gate, _params, _context) do
      {:error,
       %{
         code: "changes_outside_allowed_scope",
         allowed_scope: ["lib/"],
         unexpected_paths: ["notes.txt"]
       }}
    end

    def run(Hancho.Actions.Implement, params, _context) do
      {:ok,
       %{
         provider: params.provider,
         harness_run_id: "repair-harness-1",
         status: "completed",
         text: "attempted",
         text_truncated: false
       }}
    end
  end

  test "loads the default ordered workflow and validates action references" do
    directory = temporary_directory()
    path = Path.join(directory, "implement.yaml")
    File.write!(path, Hancho.Workflow.Default.implementation())

    assert Hancho.Workflow.Default.implementation() ==
             File.read!(Path.expand("../../priv/workflows/implement.yaml", __DIR__))

    assert Hancho.Workflow.Default.implementation_prompt() ==
             File.read!(Path.expand("../../priv/prompts/implement.md", __DIR__))

    assert {:ok, definition} = Loader.load_path(path)
    assert definition.name == "implement"
    assert length(definition.steps) == 11
    assert hd(definition.steps).name == "preflight"
    assert List.last(definition.steps).name == "close_issue"

    assert Enum.all?(definition.steps, fn step ->
             match?({:ok, _module}, Hancho.Workflow.Registry.fetch(step.action))
           end)
  end

  test "rejects duplicate names and forward step references" do
    duplicate = %{
      "name" => "bad",
      "version" => 1,
      "steps" => [
        %{"name" => "same", "action" => "Test.First", "params" => %{}},
        %{"name" => "same", "action" => "Test.Second", "params" => %{}}
      ]
    }

    assert {:error, "Step names must be unique."} = Definition.new(duplicate)

    forward = %{
      "name" => "bad",
      "version" => 1,
      "steps" => [
        %{
          "name" => "first",
          "action" => "Test.First",
          "params" => %{"value" => "$steps.second.value"}
        },
        %{"name" => "second", "action" => "Test.Second", "params" => %{}}
      ]
    }

    assert {:error, message} = Definition.new(forward)
    assert message =~ "refers to unavailable step 'second'"
  end

  test "validates bounded repair policies on approved gates" do
    assert {:ok, definition} =
             Definition.new(%{
               name: "repairable",
               version: 1,
               steps: [
                 %{
                   name: "verify",
                   action: "Hancho.Actions.Verify",
                   params: %{},
                   on_error: %{
                     codes: ["verification_failed"],
                     repair_with: "grok",
                     max_attempts: 1,
                     retry_step: "verify"
                   }
                 }
               ]
             })

    assert definition.steps |> hd() |> Map.fetch!(:on_error) |> Map.fetch!(:timeout_ms) == 600_000

    invalid_retry =
      definition.steps
      |> hd()
      |> Map.from_struct()
      |> Map.update!(:on_error, &(&1 |> Map.from_struct() |> Map.put(:retry_step, "other")))

    assert {:error, "Step 'verify' can retry only itself after a repair."} =
             Definition.new(%{name: "invalid", version: 1, steps: [invalid_retry]})

    unsupported =
      invalid_retry
      |> Map.update!(:on_error, fn policy ->
        policy
        |> Map.put(:retry_step, "verify")
        |> Map.put(:codes, ["filesystem_out_of_sync"])
      end)

    assert {:error, message} =
             Definition.new(%{name: "invalid", version: 1, steps: [unsupported]})

    assert message =~ "unsupported repair codes"
  end

  test "resolves input, run, and prior-step values through nested data" do
    scope = %{
      "input" => %{"issue_id" => "hancho-123"},
      "run" => %{"id" => "run-1"},
      "steps" => %{"first" => %{"value" => 4}}
    }

    params = %{
      "issue" => "$input.issue_id",
      "path" => ["$run.id", %{"number" => "$steps.first.value"}],
      "literal" => "plain"
    }

    assert Params.resolve(params, scope) ==
             {:ok,
              %{
                "issue" => "hancho-123",
                "path" => ["run-1", %{"number" => 4}],
                "literal" => "plain"
              }}

    assert Params.resolve("$steps.missing.value", scope) ==
             {:error, "Parameter reference was not found: $steps.missing.value"}
  end

  test "runs steps in order and keeps completed state in Bedrock" do
    {project, workflow_path} = project_with_workflow(successful_workflow())
    assert File.exists?(workflow_path)

    assert {:ok, result} =
             Runner.run(project, "test", %{"number" => 3},
               run_id: "run-success",
               registry: Registry,
               executor: Executor,
               log: :disabled,
               flush_state: false
             )

    assert result.status == :completed

    assert result.outputs == %{
             "first" => %{"value" => 4},
             "second" => %{"value" => 8}
           }

    assert {:ok, store} = Store.open(project.bedrock_path)
    assert {:ok, run} = Store.fetch_run(store, "run-success")
    assert run["status"] == "completed"
    assert run["workflow_yaml"] == successful_workflow()
    assert run["workflow_sha256"] == sha256(successful_workflow())
    assert Jason.decode!(run["outputs_json"]) == result.outputs

    assert {:ok, steps} = Store.list_steps(store, "run-success")
    assert Enum.map(steps, & &1["status"]) == ["completed", "completed"]
    Store.flush(store)
  end

  test "passes verbose mode to workflow actions" do
    {project, _workflow_path} = project_with_workflow(successful_workflow())

    assert {:ok, %{status: :completed}} =
             Runner.run(project, "test", %{"number" => 3},
               run_id: "run-verbose",
               registry: Registry,
               executor: ContextExecutor,
               services: %{test_pid: self()},
               verbose: true,
               log: :disabled,
               flush_state: false
             )

    assert_received {:action_verbose, true}
  end

  test "stops on a missing parameter and keeps the Andon state in Bedrock" do
    {project, _workflow_path} = project_with_workflow(successful_workflow())

    assert {:ok, result} =
             Runner.run(project, "test", %{"number" => 3},
               run_id: "run-stopped",
               registry: Registry,
               executor: MissingOutputExecutor,
               failure_cleanup: RecordingFailureCleanup,
               test_pid: self(),
               log: :disabled,
               flush_state: false
             )

    assert result.status == :stopped
    assert result.current_step == "second"
    assert result.error =~ "$steps.first.value"
    assert result.cleanup == %{status: "completed", removed: ["_build", "deps"]}

    assert result.forensic_report ==
             Path.join(project.forensics_path, "runs/run-stopped.json")

    assert File.regular?(result.forensic_report)
    assert_received {:failure_cleanup, project_root, "second"}
    assert project_root == project.root

    assert {:ok, store} = Store.open(project.bedrock_path)
    assert {:ok, run} = Store.fetch_run(store, "run-stopped")
    assert run["status"] == "stopped"
    assert run["current_step"] == "second"

    assert {:ok, steps} = Store.list_steps(store, "run-stopped")
    assert Enum.map(steps, & &1["status"]) == ["completed", "stopped"]
    Store.flush(store)
  end

  test "retries only the stopped step and preserves completed outputs" do
    {project, _workflow_path} = project_with_workflow(successful_workflow())

    assert {:ok, stopped} =
             Runner.run(project, "test", %{"number" => 3},
               run_id: "run-retry",
               registry: Registry,
               executor: TransientExecutor,
               services: %{test_pid: self()},
               log: :disabled,
               flush_state: false
             )

    assert stopped.status == :stopped
    assert stopped.current_step == "second"
    assert_received :first_executed
    assert_received :second_executed

    assert {:ok, completed} =
             Runner.retry(project, "run-retry",
               registry: Registry,
               executor: TransientExecutor,
               services: %{test_pid: self()},
               reconciler: RetryReconciler,
               log: :disabled,
               flush_state: false
             )

    assert completed.status == :completed

    assert completed.outputs == %{
             "first" => %{"value" => 4},
             "second" => %{"value" => 8}
           }

    assert_received {:retry_reconciled, %{"first" => %{"value" => 4}}}
    refute_received :first_executed
    assert_received :second_executed

    assert {:ok, store} = Store.open(project.bedrock_path)
    assert {:ok, run} = Store.fetch_run(store, "run-retry")
    assert run["status"] == "completed"
    assert {:ok, steps} = Store.list_steps(store, "run-retry")
    assert Enum.map(steps, & &1["status"]) == ["completed", "completed"]
    Store.flush(store)
  end

  test "persists a recovery Andon when retry reconciliation fails" do
    {project, _workflow_path} = project_with_workflow(successful_workflow())

    assert {:ok, stopped} =
             Runner.run(project, "test", %{"number" => 3},
               run_id: "run-recovery-andon",
               registry: Registry,
               executor: TransientExecutor,
               services: %{test_pid: self()},
               log: :disabled,
               flush_state: false
             )

    assert stopped.status == :stopped
    assert_received :first_executed
    assert_received :second_executed

    assert {:ok, recovery} =
             Runner.retry(project, "run-recovery-andon",
               registry: Registry,
               executor: TransientExecutor,
               services: %{test_pid: self()},
               reconciler: FailingRetryReconciler,
               log: :disabled,
               flush_state: false
             )

    assert recovery.status == :stopped
    assert recovery.current_step == "second"
    assert recovery.error.code == "recovery_reconciliation_failed"
    assert recovery.error.error["code"] == "filesystem_out_of_sync"
    assert File.regular?(recovery.forensic_report)
    refute_received :second_executed

    assert {:ok, store} = Store.open(project.bedrock_path)
    assert {:ok, run} = Store.fetch_run(store, "run-recovery-andon")
    assert run["status"] == "recovery_required"
    assert Jason.decode!(run["error_json"])["code"] == "recovery_reconciliation_failed"

    assert {:ok, steps} = Store.list_steps(store, "run-recovery-andon")
    assert Enum.map(steps, & &1["status"]) == ["completed", "recovery_required"]
    assert :ok = Store.flush(store)
  end

  test "starts the next step after a crash between sequential steps" do
    {project, _workflow_path} = project_with_workflow(successful_workflow())
    assert {:ok, definition, source} = Loader.load_with_source(project, "test")
    assert {:ok, store} = Store.open(project.bedrock_path)

    assert :ok =
             Store.create_run(store, "run-between-steps", definition, %{"number" => 3}, source)

    assert :ok = Store.start_step(store, "run-between-steps", 0, hd(definition.steps), %{})

    assert :ok =
             Store.complete_step(store, "run-between-steps", 0, %{"value" => 4}, %{
               "first" => %{"value" => 4}
             })

    assert :ok = Store.flush(store)

    assert {:ok, completed} =
             Runner.retry(project, "run-between-steps",
               registry: Registry,
               executor: TransientExecutor,
               services: %{test_pid: self()},
               reconciler: RetryReconciler,
               log: :disabled,
               flush_state: false
             )

    assert completed.status == :completed
    assert completed.outputs["second"] == %{"value" => 8}
    refute_received :first_executed
    assert_received :second_executed

    assert {:ok, steps} = Store.list_steps(store, "run-between-steps")
    assert Enum.map(steps, & &1["status"]) == ["completed", "completed"]
    assert :ok = Store.flush(store)
  end

  test "retries an idempotent retry_pending transition after a crash" do
    {project, _workflow_path} = project_with_workflow(successful_workflow())
    assert {:ok, definition, source} = Loader.load_with_source(project, "test")
    assert {:ok, store} = Store.open(project.bedrock_path)

    assert :ok =
             Store.create_run(store, "run-retry-pending", definition, %{"number" => 3}, source)

    assert :ok = Store.start_step(store, "run-retry-pending", 0, hd(definition.steps), %{})

    assert :ok =
             Store.stop_run_and_step(
               store,
               "run-retry-pending",
               0,
               "first",
               :interrupted
             )

    assert :ok = Store.retry_run(store, "run-retry-pending", 0)
    assert :ok = Store.flush(store)

    assert {:ok, completed} =
             Runner.retry(project, "run-retry-pending",
               registry: Registry,
               executor: Executor,
               reconciler: RetryReconciler,
               log: :disabled,
               flush_state: false
             )

    assert completed.status == :completed

    assert completed.outputs == %{
             "first" => %{"value" => 4},
             "second" => %{"value" => 8}
           }

    assert {:ok, steps} = Store.list_steps(store, "run-retry-pending")
    assert Enum.map(steps, & &1["status"]) == ["completed", "completed"]
    assert :ok = Store.flush(store)
  end

  test "repairs an approved gate failure and retries only that gate" do
    {project, _workflow_path} = project_with_workflow(repair_workflow())

    assert {:ok, result} =
             Runner.run(project, "test", %{"repo_path" => project.root, "issue_id" => "task-1"},
               run_id: "run-repair",
               registry: RepairRegistry,
               executor: RepairExecutor,
               services: %{test_pid: self()},
               validate_environment: false,
               log: :disabled,
               flush_state: false
             )

    assert result.status == :completed
    assert result.outputs["validate_scope"]["status"] == "checked"
    assert [%{"status" => "completed", "attempt" => 1} = repair] = result.artifacts["repairs"]
    assert repair["provider"] == "grok"
    assert repair["code"] == "changes_outside_allowed_scope"

    assert_received {:repair_prompt, prompt, :repair}
    assert prompt =~ "Repair the failed Hancho workflow gate"
    assert prompt =~ "changes_outside_allowed_scope"
    assert prompt =~ "Do not edit the task text, Allowed Scope"

    assert {:ok, store} = Store.open(project.bedrock_path)
    assert {:ok, steps} = Store.list_steps(store, "run-repair")
    scope_step = Enum.find(steps, &(&1["name"] == "validate_scope"))
    assert {:ok, [saved]} = Hancho.Workflow.Repair.decode_records(scope_step["repairs_json"])
    assert saved["status"] == "completed"
    assert saved["prompt_sha256"] == repair["prompt_sha256"]
    Store.flush(store)
  end

  test "stops after the configured repair attempt limit" do
    {project, _workflow_path} = project_with_workflow(repair_workflow())

    assert {:ok, result} =
             Runner.run(project, "test", %{"repo_path" => project.root, "issue_id" => "task-1"},
               run_id: "run-repair-exhausted",
               registry: RepairRegistry,
               executor: ExhaustedRepairExecutor,
               validate_environment: false,
               log: :disabled,
               flush_state: false
             )

    assert result.status == :stopped
    assert result.current_step == "validate_scope"
    assert result.error["code"] == "changes_outside_allowed_scope"

    assert result.error["repair"] == %{
             "status" => "exhausted",
             "attempts" => 1,
             "max_attempts" => 1
           }

    assert [%{"status" => "completed", "attempt" => 1}] = result.artifacts["repairs"]
    assert File.regular?(result.forensic_report)
  end

  test "recovers a run that stopped after a step started" do
    {project, _workflow_path} = project_with_workflow(successful_workflow())
    {:ok, definition, source} = Loader.load_with_source(project, "test")
    first = hd(definition.steps)

    assert {:ok, store} = Store.open(project.bedrock_path)
    assert :ok = Store.create_run(store, "run-interrupted", definition, %{"number" => 3}, source)
    assert :ok = Store.start_step(store, "run-interrupted", 0, first, first.params)
    assert :ok = Store.flush(store)

    assert {:ok, completed} =
             Runner.retry(project, "run-interrupted",
               registry: Registry,
               executor: Executor,
               reconciler: RetryReconciler,
               log: :disabled,
               flush_state: false
             )

    assert completed.status == :completed
    assert completed.outputs["second"] == %{"value" => 8}

    assert {:ok, reopened} = Store.open(project.bedrock_path)
    assert {:ok, run} = Store.fetch_run(reopened, "run-interrupted")
    assert run["status"] == "completed"
    assert run["transition_version"] > 0
    Store.flush(reopened)
  end

  test "finalizes a stopped run when every step is already complete" do
    {project, _workflow_path} = project_with_workflow(successful_workflow())
    {:ok, definition, source} = Loader.load_with_source(project, "test")
    [first, second] = definition.steps

    assert {:ok, store} = Store.open(project.bedrock_path)
    assert :ok = Store.create_run(store, "run-final-step", definition, %{"number" => 3}, source)
    assert :ok = Store.start_step(store, "run-final-step", 0, first, first.params)
    assert :ok = Store.complete_step(store, "run-final-step", 0, %{"value" => 4}, %{})
    assert :ok = Store.start_step(store, "run-final-step", 1, second, second.params)
    assert :ok = Store.complete_step(store, "run-final-step", 1, %{"value" => 8}, %{})

    assert :ok =
             Store.fail_run(
               store,
               "run-final-step",
               "second",
               %{},
               {:bedrock, "expected a map, got a durability marker"}
             )

    assert {:ok, completed} =
             Runner.retry(project, "run-final-step",
               registry: Registry,
               executor: Executor,
               reconciler: RetryReconciler,
               log: :disabled,
               flush_state: false
             )

    assert completed.status == :completed
    assert completed.current_step == nil
    expected_outputs = %{"first" => %{"value" => 4}, "second" => %{"value" => 8}}
    assert completed.outputs == expected_outputs
    assert_received {:retry_reconciled, ^expected_outputs}

    assert {:ok, run} = Store.fetch_run(store, "run-final-step")
    assert run["status"] == "completed"
    assert run["current_step"] == nil
    assert run["error_json"] == nil
    Store.flush(store)
  end

  test "rejects completion while a run has an incomplete step" do
    {project, _workflow_path} = project_with_workflow(successful_workflow())
    {:ok, definition, source} = Loader.load_with_source(project, "test")

    assert {:ok, store} = Store.open(project.bedrock_path)
    assert :ok = Store.create_run(store, "run-incomplete", definition, %{"number" => 3}, source)
    assert :ok = Store.start_step(store, "run-incomplete", 0, hd(definition.steps), %{})
    assert {:error, :run_has_incomplete_steps} = Store.complete_run(store, "run-incomplete", %{})
    assert {:ok, run} = Store.fetch_run(store, "run-incomplete")
    assert run["status"] == "running"
    Store.flush(store)
  end

  test "runs the default workflow through all approved actions" do
    repository = temporary_repository()
    project = Hancho.Project.new(repository)
    File.mkdir_p!(project.worktrees_path)
    assert :ok = Hancho.Workflow.Default.install(project)
    write_quiet_log_config(project)

    assert {:ok, result} =
             Runner.run(
               project,
               "implement",
               %{"repo_path" => repository, "issue_id" => "hancho-123"},
               run_id: "full-run",
               flush_state: false,
               services: %{beadwork: Beadwork, harness: Harness, command: Command}
             )

    assert result.status == :completed
    assert map_size(result.outputs) == 11
    assert result.outputs["render_prompt"]["rendered"] =~ "Implement Beadwork task hancho-123"
    assert result.outputs["close_issue"]["status"] == "closed"
    assert File.read!(Path.join(repository, "implemented.txt")) == "implemented\n"
    refute File.exists?(Path.join(project.worktrees_path, "full-run"))

    assert {:ok, store} = Store.open(project.bedrock_path)
    assert {:ok, run} = Store.fetch_run(store, "full-run")
    assert run["workflow_yaml"] == Hancho.Workflow.Default.implementation()
    assert run["workflow_sha256"] == sha256(Hancho.Workflow.Default.implementation())

    assert {:ok, steps} = Store.list_steps(store, "full-run")
    assert Enum.all?(steps, &(&1["status"] == "completed"))
    Store.flush(store)

    events = read_events(Path.join(project.logs_path, "factory.jsonl"))
    workflow_event = Enum.find(events, &(&1["event"] == "workflow.snapshot"))
    prompt_event = Enum.find(events, &(&1["event"] == "prompt.snapshot"))

    assert workflow_event["metadata"]["yaml"] == Hancho.Workflow.Default.implementation()
    assert workflow_event["metadata"]["sha256"] == run["workflow_sha256"]
    assert prompt_event["metadata"]["template"] == Hancho.Workflow.Default.implementation_prompt()
    assert prompt_event["metadata"]["rendered"] == result.outputs["render_prompt"]["rendered"]
    assert prompt_event["metadata"]["sha256"] == result.outputs["render_prompt"]["sha256"]
  end

  test "lands a legacy workflow from its durable preflight branch artifact" do
    repository = temporary_repository()
    project = Hancho.Project.new(repository)
    File.mkdir_p!(project.worktrees_path)
    assert :ok = Hancho.Workflow.Default.install(project)
    write_quiet_log_config(project)

    legacy_workflow =
      String.replace(
        Hancho.Workflow.Default.implementation(),
        "      branch: \"$steps.preflight.branch\"\n",
        ""
      )

    refute legacy_workflow == Hancho.Workflow.Default.implementation()
    File.write!(Path.join(project.workflows_path, "implement.yaml"), legacy_workflow)

    assert {:ok, result} =
             Runner.run(
               project,
               "implement",
               %{"repo_path" => repository, "issue_id" => "hancho-123"},
               run_id: "legacy-land",
               flush_state: false,
               services: %{beadwork: Beadwork, harness: Harness, command: Command}
             )

    assert result.status == :completed
    assert result.outputs["land"]["branch"] == "main"
    assert File.read!(Path.join(repository, "implemented.txt")) == "implemented\n"
  end

  defp successful_workflow do
    """
    name: test
    version: 1
    steps:
      - name: first
        action: Test.First
        params:
          value: "$input.number"
      - name: second
        action: Test.Second
        params:
          value: "$steps.first.value"
    """
  end

  defp repair_workflow do
    """
    name: test
    version: 1
    steps:
      - name: workspace
        action: Hancho.Actions.UseRepository
        params:
          repo_path: "$input.repo_path"
      - name: validate_scope
        action: Hancho.Actions.ValidateScope
        params:
          worktree_path: "$steps.workspace.workspace_path"
        on_error:
          codes:
            - changes_outside_allowed_scope
          repair_with: grok
          max_attempts: 1
          retry_step: validate_scope
    """
  end

  defp project_with_workflow(contents) do
    root = temporary_directory()
    project = Hancho.Project.new(root)
    File.mkdir_p!(project.workflows_path)
    path = Path.join(project.workflows_path, "test.yaml")
    File.write!(path, contents)
    {project, path}
  end

  defp temporary_directory do
    path = Path.join(System.tmp_dir!(), "hancho-workflow-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)

    on_exit(fn ->
      Hancho.State.Bedrock.reset()
      File.rm_rf!(path)
    end)

    path
  end

  defp temporary_repository do
    path = temporary_directory()
    {_output, 0} = System.cmd("git", ["init", "--initial-branch=main", path])
    File.write!(Path.join(path, ".gitignore"), "/.hancho/\n")

    {_output, 0} = System.cmd("git", ["-C", path, "config", "user.name", "Hancho Test"])
    {_output, 0} = System.cmd("git", ["-C", path, "config", "user.email", "hancho@example.test"])
    {_output, 0} = System.cmd("git", ["-C", path, "add", ".gitignore"])

    {_output, 0} =
      System.cmd("git", ["-C", path, "commit", "-m", "chore: initialize test repository"])

    path
  end

  defp write_quiet_log_config(project) do
    {:ok, config} = Hancho.Config.default(project)
    config = %{config | logs: %{config.logs | console: false, sync_interval_ms: 0}}
    {:ok, contents} = Hancho.Config.encode(config)
    File.write!(project.config_path, contents)
  end

  defp read_events(path) do
    path
    |> File.stream!()
    |> Enum.map(&Jason.decode!/1)
  end

  defp sha256(contents), do: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
end
