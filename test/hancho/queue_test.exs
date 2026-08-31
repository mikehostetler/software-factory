defmodule Hancho.QueueTest do
  use ExUnit.Case, async: false

  alias Hancho.Workflow.{
    QueueReconciler,
    QueueReporter,
    QueueRunner,
    Result,
    RunReconciler,
    Store
  }

  defmodule Beadwork do
    def ready(_options) do
      {:ok,
       [
         issue("task-1"),
         %{"id" => "epic-1", "type" => "epic", "status" => "open", "blocked_by" => []},
         issue("task-2"),
         issue("task-3")
       ]}
    end

    def list_all(_options), do: {:ok, [epic() | Enum.map(1..3, &issue("task-#{&1}"))]}

    defp issue(id) do
      %{
        "id" => id,
        "type" => "task",
        "status" => "open",
        "parent" => "epic-1",
        "blocked_by" => [],
        "description" => mapping(id)
      }
    end

    defp mapping(id),
      do:
        "Hancho-GitHub-Sub-Issue: https://github.test/issues/#{id}\nHancho-GitHub-Node: node-#{id}"

    defp epic, do: mapped_epic()

    defp mapped_epic do
      %{
        "id" => "epic-1",
        "type" => "epic",
        "status" => "open",
        "description" =>
          "Hancho-GitHub-Issue: https://github.test/issues/epic-1\nHancho-GitHub-Node: node-epic-1"
      }
    end
  end

  defmodule ContainerReadyBeadwork do
    def ready(_options) do
      {:ok, [%{"id" => "epic-1", "type" => "epic", "status" => "open", "blocked_by" => []}]}
    end

    def list_all(_options) do
      {:ok,
       [
         mapped_epic(),
         issue("task-later", "open", ["task-next"], 20),
         issue("task-closed", "closed", [], 5),
         issue("task-next", "open", ["task-closed"], 10)
       ]}
    end

    defp mapped_epic do
      %{
        "id" => "epic-1",
        "type" => "epic",
        "status" => "open",
        "description" =>
          "Hancho-GitHub-Issue: https://github.test/issues/epic-1\nHancho-GitHub-Node: node-epic-1"
      }
    end

    defp issue(id, status, blocked_by, ordinal) do
      %{
        "id" => id,
        "type" => "task",
        "status" => status,
        "blocked_by" => blocked_by,
        "parent" => "epic-1",
        "description" =>
          "Queue ordinal: `#{ordinal}`\nHancho-GitHub-Sub-Issue: https://github.test/issues/#{id}\nHancho-GitHub-Node: node-#{id}"
      }
    end
  end

  defmodule InsufficientReadyBeadwork do
    def ready(_options), do: {:ok, [issue("task-2", 20)]}

    def list_all(_options) do
      {:ok, [mapped_epic(), issue("task-2", 20), issue("task-1", 10)]}
    end

    defp mapped_epic do
      %{
        "id" => "epic-1",
        "type" => "epic",
        "status" => "open",
        "description" =>
          "Hancho-GitHub-Issue: https://github.test/issues/epic-1\nHancho-GitHub-Node: node-epic-1"
      }
    end

    defp issue(id, ordinal) do
      %{
        "id" => id,
        "title" => id,
        "type" => "task",
        "status" => "open",
        "blocked_by" => [],
        "parent" => "epic-1",
        "description" =>
          "Queue ordinal: `#{ordinal}`\nHancho-GitHub-Sub-Issue: https://github.test/issues/#{id}\nHancho-GitHub-Node: node-#{id}"
      }
    end
  end

  defmodule UnresolvedBlockerBeadwork do
    def ready(_options), do: {:ok, []}

    def list_all(_options) do
      {:ok,
       [
         %{
           "id" => "epic-1",
           "type" => "epic",
           "status" => "open",
           "description" =>
             "Hancho-GitHub-Issue: https://github.test/issues/epic-1\nHancho-GitHub-Node: node-epic-1"
         },
         %{
           "id" => "task-blocked",
           "type" => "task",
           "status" => "open",
           "blocked_by" => ["task-missing"],
           "parent" => "epic-1",
           "description" =>
             "Queue ordinal: `10`\nHancho-GitHub-Sub-Issue: https://github.test/issues/task-blocked\nHancho-GitHub-Node: node-task-blocked"
         }
       ]}
    end
  end

  defmodule Reconciler do
    def initial(project, _options) do
      {:ok, %{repository: project.root, branch: "main", head: "head-0", worktrees: []}}
    end

    def before_item(_project, queue, _options) do
      send(self(), {:reconciled, :before, queue["current_position"]})
      {:ok, summary(queue["expected_head"])}
    end

    def after_run(_project, queue, artifacts, _options) do
      send(self(), {:reconciled, :after, queue["current_position"]})
      {:ok, summary(get_in(artifacts, ["landing", "commit"]) || queue["expected_head"])}
    end

    defp summary(head), do: %{branch: "main", head: head, clean: true, worktrees: []}
  end

  defmodule PreviewLoader do
    def load(_project, "implement") do
      Hancho.Workflow.Definition.new(%{
        name: "implement",
        version: 1,
        steps: [
          %{
            name: "workspace",
            action: "Hancho.Actions.UseRepository",
            params: %{
              "repo_path" => "$input.repo_path",
              "baseline" => "head-0"
            }
          },
          %{
            name: "implement",
            action: "Hancho.Actions.Implement",
            params: %{
              "prompt" => "Implement the selected task.",
              "worktree_path" => "$input.repo_path",
              "provider" => "grok",
              "reasoning_effort" => "xhigh",
              "timeout_ms" => 1_800_000
            }
          },
          %{
            name: "verify",
            action: "Hancho.Actions.Verify",
            params: %{
              "worktree_path" => "$input.repo_path",
              "executable" => "mix",
              "arguments" => [],
              "timeout_ms" => 600_000
            }
          }
        ]
      })
    end
  end

  defmodule MismatchReconciler do
    def initial(project, _options) do
      {:ok, %{repository: project.root, branch: "main", head: "head-0", worktrees: []}}
    end

    def before_item(_project, _queue, _options) do
      {:error,
       %{
         code: "filesystem_out_of_sync",
         field: "head",
         expected: "head-0",
         actual: "head-other"
       }}
    end
  end

  defmodule StoppedMismatchReconciler do
    def initial(project, _options) do
      {:ok, %{repository: project.root, branch: "main", head: "head-0", worktrees: []}}
    end

    def before_item(_project, queue, _options) do
      {:ok, %{branch: "main", head: queue["expected_head"], clean: true, worktrees: []}}
    end

    def after_run(_project, queue, artifacts, _options) do
      {:ok,
       %{
         branch: "main",
         head: get_in(artifacts, ["landing", "commit"]) || queue["expected_head"],
         clean: true,
         worktrees: []
       }}
    end

    def after_stopped_run(_project, _queue, _artifacts, _options) do
      {:error,
       %{
         code: "filesystem_out_of_sync",
         field: "repository_status",
         expected: "clean",
         actual: [%{path: "unexpected.txt", index: "?", working_tree: "?"}]
       }}
    end
  end

  defmodule WorkflowRunner do
    def run(_project, "implement", %{"issue_id" => issue_id}, options) do
      send(self(), {:ran, issue_id, options[:run_id]})

      Result.new(%{
        run_id: options[:run_id],
        workflow: "implement",
        status: :completed,
        current_step: nil,
        outputs: %{"land" => %{"commit" => "head-#{issue_id}"}},
        artifacts: %{"landing" => %{"commit" => "head-#{issue_id}"}},
        error: nil
      })
    end
  end

  defmodule StoppingWorkflowRunner do
    def run(_project, "implement", %{"issue_id" => "task-2"}, options) do
      send(self(), {:ran, "task-2", options[:run_id]})

      Result.new(%{
        run_id: options[:run_id],
        workflow: "implement",
        status: :stopped,
        current_step: "implement",
        outputs: %{},
        error: "agent stopped"
      })
    end

    def run(project, workflow, input, options),
      do: WorkflowRunner.run(project, workflow, input, options)
  end

  defmodule RetryWorkflowRunner do
    def retry(_project, "queue-stop-002", options) do
      send(self(), {:retried, "task-2", options[:run_id]})

      Result.new(%{
        run_id: options[:run_id],
        workflow: "implement",
        status: :completed,
        current_step: nil,
        outputs: %{"land" => %{"commit" => "head-task-2"}},
        artifacts: %{"landing" => %{"commit" => "head-task-2"}},
        error: nil
      })
    end

    def run(project, workflow, input, options),
      do: WorkflowRunner.run(project, workflow, input, options)
  end

  defmodule MustNotRecoverWorkflow do
    def retry(_project, _run_id, _options) do
      send(self(), :unexpected_child_retry)
      {:error, :must_not_retry}
    end

    def run(_project, _workflow, _input, _options) do
      send(self(), :unexpected_child_run)
      {:error, :must_not_run}
    end
  end

  defmodule MemoryStore do
    def open(_path), do: {:ok, :memory}

    def flush(_store) do
      send(self(), :store_flushed)
      :ok
    end

    def create_queue(_store, id, workflow, source, items, state) do
      queue = %{
        "id" => id,
        "workflow_name" => workflow,
        "source" => source,
        "status" => "running",
        "repository" => state.repository,
        "expected_branch" => state.branch,
        "expected_head" => state.head,
        "expected_worktrees" => Map.get(state, :expected_worktrees, []),
        "current_position" => 0,
        "current_run_id" => nil,
        "items" =>
          Enum.map(items, fn item ->
            %{
              "position" => item.position,
              "issue_id" => item.issue_id,
              "run_id" => item.run_id,
              "status" => "pending",
              "error" => nil
            }
          end),
        "error" => nil
      }

      Process.put({__MODULE__, id}, queue)
      :ok
    end

    def fetch_queue(_store, id), do: {:ok, Process.get({__MODULE__, id})}

    def start_queue_item(_store, id, position) do
      update(id, fn queue ->
        item = Enum.at(queue["items"], position) |> Map.put("status", "running")

        queue
        |> put_item(position, item)
        |> Map.put("current_run_id", item["run_id"])
      end)
    end

    def complete_queue_item(_store, id, position, head) do
      update(id, fn queue ->
        item = Enum.at(queue["items"], position) |> Map.put("status", "completed")

        queue
        |> put_item(position, item)
        |> Map.put("expected_head", head)
        |> Map.put("current_position", position + 1)
        |> Map.put("current_run_id", nil)
      end)
    end

    def stop_queue_item(_store, id, position, error) do
      update(id, fn queue ->
        item =
          queue["items"]
          |> Enum.at(position)
          |> Map.put("status", "stopped")
          |> Map.put("error", error)

        queue
        |> put_item(position, item)
        |> Map.put("status", "stopped")
        |> Map.put("error", error)
      end)
    end

    def resume_queue(_store, id) do
      update(id, fn queue ->
        position = queue["current_position"]
        item = Enum.at(queue["items"], position) |> Map.put("status", "running")

        queue
        |> put_item(position, item)
        |> Map.put("status", "running")
        |> Map.put("error", nil)
      end)
    end

    def complete_queue(_store, id), do: update(id, &Map.put(&1, "status", "completed"))

    defp update(id, function) do
      Process.put({__MODULE__, id}, function.(Process.get({__MODULE__, id})))
      :ok
    end

    defp put_item(queue, position, item) do
      Map.update!(queue, "items", &List.replace_at(&1, position, item))
    end
  end

  defmodule CompletionFlushStore do
    def open(path), do: MemoryStore.open(path)

    def create_queue(store, id, workflow, source, items, state),
      do: MemoryStore.create_queue(store, id, workflow, source, items, state)

    def fetch_queue(store, id), do: MemoryStore.fetch_queue(store, id)

    def start_queue_item(store, id, position),
      do: MemoryStore.start_queue_item(store, id, position)

    def complete_queue_item(store, id, position, head) do
      with :ok <- MemoryStore.complete_queue_item(store, id, position, head) do
        Process.put({__MODULE__, :fail_flush}, true)
        :ok
      end
    end

    def flush(store) do
      if Process.delete({__MODULE__, :fail_flush}) do
        {:error, :disk_full}
      else
        MemoryStore.flush(store)
      end
    end

    def stop_queue_item(_store, _id, _position, _error) do
      send(self(), :unexpected_queue_stop_after_completion)
      {:error, :queue_item_not_stoppable}
    end

    def complete_queue(store, id), do: MemoryStore.complete_queue(store, id)
  end

  defmodule SummaryStore do
    def fetch_queue(:summary, "queue-summary") do
      {:ok,
       %{
         "status" => "completed",
         "current_position" => 2,
         "started_at" => "2026-08-22T12:00:00Z",
         "finished_at" => "2026-08-22T12:02:00Z",
         "error" => nil,
         "items" => [
           %{"issue_id" => "task-1", "run_id" => "run-1", "status" => "completed"},
           %{"issue_id" => "task-2", "run_id" => "run-2", "status" => "completed"}
         ]
       }}
    end

    def fetch_run(:summary, "run-1") do
      {:ok,
       run(
         "2026-08-22T12:00:00Z",
         "2026-08-22T12:01:00Z",
         "codex",
         "gpt-pinned",
         %{
           "status" => "available",
           "scope" => "run",
           "additive" => true,
           "values" => %{"input_tokens" => 10, "output_tokens" => 2, "total_tokens" => 12}
         }
       )}
    end

    def fetch_run(:summary, "run-2") do
      {:ok,
       run(
         "2026-08-22T12:01:00Z",
         "2026-08-22T12:02:00Z",
         "grok",
         nil,
         %{
           "status" => "available",
           "scope" => "provider_cumulative",
           "additive" => false,
           "values" => %{"total_tokens" => 99_999}
         }
       )}
    end

    defp run(started_at, finished_at, provider, model, usage) do
      %{
        "started_at" => started_at,
        "finished_at" => finished_at,
        "outputs_json" =>
          Jason.encode!(%{
            "implement" => %{
              "harness_run_id" => "harness-#{provider}",
              "provider" => provider,
              "model" => model,
              "usage" => usage
            }
          })
      }
    end
  end

  test "reports per-task elapsed and excludes cumulative usage from queue totals" do
    assert {:ok, result} =
             QueueReporter.result(SummaryStore, :summary, "queue-summary", "implement")

    assert result.elapsed_ms == 120_000
    assert Enum.map(result.task_summaries, & &1["elapsed_ms"]) == [60_000, 60_000]
    assert Enum.map(result.task_summaries, & &1["model"]) == ["gpt-pinned", nil]
    assert result.usage_summary["status"] == "partial"
    assert result.usage_summary["values"]["total_tokens"] == 12
    assert result.usage_summary["excluded_task_count"] == 1
  end

  test "runs selected tasks serially with verbose reconciliation progress" do
    project = Hancho.Project.new(temporary_directory())
    parent = self()

    assert {:ok, result} =
             QueueRunner.run(project, "implement", "beadwork-ready", 3,
               beadwork: Beadwork,
               reconciler: Reconciler,
               workflow_runner: WorkflowRunner,
               store_api: MemoryStore,
               queue_id: "queue-test",
               verbose: true,
               progress: fn message ->
                 send(parent, {:progress, message})
                 :ok
               end
             )

    assert result.status == :completed
    assert result.completed_count == 3
    assert result.child_runs == ["queue-test-001", "queue-test-002", "queue-test-003"]

    assert_received {:ran, "task-1", "queue-test-001"}
    assert_received {:ran, "task-2", "queue-test-002"}
    assert_received {:ran, "task-3", "queue-test-003"}
    assert_received {:reconciled, :before, 0}
    assert_received {:reconciled, :after, 2}
    assert_received {:progress, "Reconciled before item 1: main at head-0, clean, 0 worktrees."}
    assert_received {:progress, "Queue queue-test completed 3/3 tasks."}

    assert 8 ==
             self()
             |> Process.info(:messages)
             |> elem(1)
             |> Enum.count(&(&1 == :store_flushed))

    events = read_events(Path.join(project.logs_path, "factory.jsonl"))
    assert Enum.any?(events, &(&1["event"] == "queue.started"))
    assert Enum.count(events, &(&1["event"] == "queue.reconciled")) == 6
    assert Enum.any?(events, &(&1["event"] == "queue.completed"))
    assert Enum.all?(events, &(&1["metadata"]["queue_id"] == "queue-test"))
  end

  test "keeps completed queue state visible when its durability flush fails" do
    project = Hancho.Project.new(temporary_directory())

    assert {:error,
            %{
              code: "queue_state_flush_failed",
              queue_id: "queue-flush-failure",
              transition: "item_completed",
              flush_error: "disk_full"
            }} =
             QueueRunner.run(project, "implement", "beadwork-ready", 1,
               beadwork: Beadwork,
               reconciler: Reconciler,
               workflow_runner: WorkflowRunner,
               store_api: CompletionFlushStore,
               queue_id: "queue-flush-failure",
               log: :disabled
             )

    refute_received :unexpected_queue_stop_after_completion
    assert {:ok, queue} = MemoryStore.fetch_queue(:memory, "queue-flush-failure")
    assert queue["current_position"] == 1
    assert hd(queue["items"])["status"] == "completed"
  end

  test "previews task readiness from all issues when ready returns only containers" do
    project = Hancho.Project.new(temporary_directory())

    assert {:ok, preview} =
             QueueRunner.preview(project, "implement", "beadwork-ready", 1,
               beadwork: ContainerReadyBeadwork,
               reconciler: Reconciler,
               loader: PreviewLoader,
               validate_environment: false
             )

    assert preview.issues == [%{"id" => "task-next", "status" => "open"}]

    assert preview.repository == %{
             branch: "main",
             head: "head-0",
             clean: true,
             worktrees: []
           }

    assert preview.settings == %{
             provider: "grok",
             model: nil,
             reasoning_effort: "xhigh",
             implementation_timeout_ms: 1_800_000,
             verification_timeout_ms: 600_000,
             repairs: []
           }

    assert Enum.map(preview.compilation.steps, & &1.action) == [
             "Hancho.Actions.UseRepository",
             "Hancho.Actions.Implement",
             "Hancho.Actions.Verify"
           ]

    refute File.exists?(project.bedrock_path)
  end

  test "selects a serial dependency chain in queue order" do
    project = Hancho.Project.new(temporary_directory())

    assert {:ok, preview} =
             QueueRunner.preview(project, "implement", "beadwork-ready", 2,
               beadwork: ContainerReadyBeadwork,
               reconciler: Reconciler,
               loader: PreviewLoader,
               validate_environment: false
             )

    assert Enum.map(preview.issues, & &1["id"]) == ["task-next", "task-later"]
  end

  test "does not select a task with an unresolved blocker" do
    project = Hancho.Project.new(temporary_directory())

    assert {:error, "Beadwork has 0 ready tasks; 1 are required."} =
             QueueRunner.preview(project, "implement", "beadwork-ready", 1,
               beadwork: UnresolvedBlockerBeadwork,
               reconciler: Reconciler,
               loader: PreviewLoader,
               validate_environment: false
             )
  end

  test "fills an insufficient ready task result from all issues" do
    project = Hancho.Project.new(temporary_directory())

    assert {:ok, preview} =
             QueueRunner.preview(project, "implement", "beadwork-ready", 2,
               beadwork: InsufficientReadyBeadwork,
               reconciler: Reconciler,
               loader: PreviewLoader,
               validate_environment: false
             )

    assert Enum.map(preview.issues, & &1["id"]) == ["task-1", "task-2"]
  end

  test "stops on the first failed child and leaves later items pending" do
    project = Hancho.Project.new(temporary_directory())

    assert {:ok, result} =
             QueueRunner.run(project, "implement", "beadwork-ready", 3,
               beadwork: Beadwork,
               reconciler: Reconciler,
               workflow_runner: StoppingWorkflowRunner,
               store_api: MemoryStore,
               queue_id: "queue-stop",
               log: :disabled
             )

    assert result.status == :stopped
    assert result.completed_count == 1
    assert result.current_issue == "task-2"
    refute_received {:ran, "task-3", _run_id}

    assert {:ok, queue} = MemoryStore.fetch_queue(:memory, "queue-stop")
    assert Enum.map(queue["items"], & &1["status"]) == ["completed", "stopped", "pending"]
  end

  test "does not let a progress callback failure stop the queue" do
    project = Hancho.Project.new(temporary_directory())

    assert {:ok, result} =
             QueueRunner.run(project, "implement", "beadwork-ready", 1,
               beadwork: Beadwork,
               reconciler: Reconciler,
               workflow_runner: WorkflowRunner,
               store_api: MemoryStore,
               queue_id: "queue-progress-failure",
               log: :disabled,
               progress: fn _message -> raise "output closed" end
             )

    assert result.status == :completed
  end

  test "resumes a stopped queue without repeating completed children" do
    project = Hancho.Project.new(temporary_directory())

    assert {:ok, stopped} =
             QueueRunner.run(project, "implement", "beadwork-ready", 3,
               beadwork: Beadwork,
               reconciler: Reconciler,
               workflow_runner: StoppingWorkflowRunner,
               store_api: MemoryStore,
               queue_id: "queue-stop",
               log: :disabled
             )

    assert stopped.status == :stopped
    assert_received {:ran, "task-1", "queue-stop-001"}
    assert_received {:ran, "task-2", "queue-stop-002"}

    assert {:ok, resumed} =
             QueueRunner.resume(project, "queue-stop",
               reconciler: Reconciler,
               workflow_runner: RetryWorkflowRunner,
               store_api: MemoryStore,
               log: :disabled
             )

    assert resumed.status == :completed
    assert resumed.completed_count == 3
    assert_received {:retried, "task-2", "queue-stop-002"}
    assert_received {:ran, "task-3", "queue-stop-003"}
    refute_received {:ran, "task-1", _run_id}

    assert {:ok, queue} = MemoryStore.fetch_queue(:memory, "queue-stop")
    assert Enum.map(queue["items"], & &1["status"]) == ["completed", "completed", "completed"]
  end

  test "starts a saved child when the queue stopped before child creation" do
    project = Hancho.Project.new(temporary_directory())
    items = [%{position: 0, issue_id: "task-1", run_id: "queue-pre-child-001"}]
    state = %{repository: project.root, branch: "main", head: "head-0"}

    assert {:ok, store} = Store.open(project.bedrock_path)

    assert :ok =
             Store.create_queue(
               store,
               "queue-pre-child",
               "implement",
               "beadwork-ready",
               items,
               state
             )

    assert :ok = Store.start_queue_item(store, "queue-pre-child", 0)
    assert :ok = Store.stop_queue_item(store, "queue-pre-child", 0, :interrupted)
    assert :ok = Store.flush(store)

    assert {:ok, result} =
             QueueRunner.resume(project, "queue-pre-child",
               reconciler: Reconciler,
               workflow_runner: WorkflowRunner,
               log: :disabled
             )

    assert result.status == :completed
    assert_received {:ran, "task-1", "queue-pre-child-001"}
  end

  test "adopts a completed child after a crash before queue bookkeeping" do
    project = Hancho.Project.new(temporary_directory())
    queue_id = "queue-completed-child"
    run_id = "#{queue_id}-001"
    item = %{position: 0, issue_id: "task-1", run_id: run_id}
    state = %{repository: project.root, branch: "main", head: "head-0"}

    assert {:ok, store} = Store.open(project.bedrock_path)
    assert :ok = Store.create_queue(store, queue_id, "implement", "beadwork-ready", [item], state)
    assert :ok = Store.start_queue_item(store, queue_id, 0)
    assert :ok = create_completed_child(store, run_id, "head-task-1")
    assert :ok = Store.flush(store)

    assert {:ok, result} =
             QueueRunner.resume(project, queue_id,
               reconciler: Reconciler,
               workflow_runner: MustNotRecoverWorkflow,
               log: :disabled
             )

    assert result.status == :completed
    assert result.completed_count == 1
    refute_received :unexpected_child_retry
    refute_received :unexpected_child_run

    assert {:ok, queue} = Store.fetch_queue(store, queue_id)
    assert queue["status"] == "completed"
    assert hd(queue["items"])["status"] == "completed"
  end

  test "finishes a queue after a crash following final item bookkeeping" do
    project = Hancho.Project.new(temporary_directory())
    queue_id = "queue-final-bookkeeping"
    run_id = "#{queue_id}-001"
    item = %{position: 0, issue_id: "task-1", run_id: run_id}
    state = %{repository: project.root, branch: "main", head: "head-0"}

    assert {:ok, store} = Store.open(project.bedrock_path)
    assert :ok = Store.create_queue(store, queue_id, "implement", "beadwork-ready", [item], state)
    assert :ok = Store.start_queue_item(store, queue_id, 0)
    assert :ok = create_completed_child(store, run_id, "head-task-1")
    assert :ok = Store.complete_queue_item(store, queue_id, 0, "head-task-1")
    assert :ok = Store.flush(store)

    assert {:ok, result} =
             QueueRunner.resume(project, queue_id,
               reconciler: Reconciler,
               workflow_runner: MustNotRecoverWorkflow,
               log: :disabled
             )

    assert result.status == :completed
    assert result.completed_count == 1
    refute_received :unexpected_child_retry
    refute_received :unexpected_child_run

    assert {:ok, queue} = Store.fetch_queue(store, queue_id)
    assert queue["status"] == "completed"
    assert queue["current_position"] == 1
  end

  test "stops before a child when reconciliation fails" do
    project = Hancho.Project.new(temporary_directory())

    assert {:ok, result} =
             QueueRunner.run(project, "implement", "beadwork-ready", 1,
               beadwork: Beadwork,
               reconciler: MismatchReconciler,
               workflow_runner: WorkflowRunner,
               store_api: MemoryStore,
               queue_id: "queue-mismatch",
               log: :disabled
             )

    assert result.status == :stopped
    assert result.error.code == "filesystem_out_of_sync"
    refute_received {:ran, _issue_id, _run_id}

    assert {:ok, queue} = MemoryStore.fetch_queue(:memory, "queue-mismatch")
    assert queue["status"] == "stopped"
    assert hd(queue["items"])["status"] == "stopped"
  end

  test "keeps a child workflow error when stopped-run reconciliation also fails" do
    project = Hancho.Project.new(temporary_directory())

    assert {:ok, result} =
             QueueRunner.run(project, "implement", "beadwork-ready", 2,
               beadwork: Beadwork,
               reconciler: StoppedMismatchReconciler,
               workflow_runner: StoppingWorkflowRunner,
               store_api: MemoryStore,
               queue_id: "queue-double-failure",
               log: :disabled
             )

    assert result.status == :stopped
    assert result.error.code == "workflow_stopped"
    assert result.error.step == "implement"
    assert result.error.error == "agent stopped"
    assert result.error.reconciliation.error["code"] == "filesystem_out_of_sync"
    assert File.regular?(result.forensic_report)

    report = result.forensic_report |> File.read!() |> Jason.decode!()
    assert report["queue"]["error"]["code"] == "workflow_stopped"
    assert report["queue"]["error"]["error"] == "agent stopped"

    assert report["queue"]["error"]["reconciliation"]["error"]["code"] ==
             "filesystem_out_of_sync"
  end

  test "persists queue progress in Bedrock" do
    project = Hancho.Project.new(temporary_directory())
    items = [%{position: 0, issue_id: "task-1", run_id: "queue-state-001"}]
    state = %{repository: project.root, branch: "main", head: "head-0"}

    assert {:ok, store} = Store.open(project.bedrock_path)

    assert :ok =
             Store.create_queue(store, "queue-state", "implement", "beadwork-ready", items, state)

    assert :ok = Store.start_queue_item(store, "queue-state", 0)
    assert :ok = Store.complete_queue_item(store, "queue-state", 0, "head-1")
    assert :ok = Store.complete_queue(store, "queue-state")
    assert :ok = Store.flush(store)

    assert {:ok, reopened} = Store.open(project.bedrock_path)
    assert {:ok, queue} = Store.fetch_queue(reopened, "queue-state")
    assert queue["status"] == "completed"
    assert queue["expected_head"] == "head-1"
    assert queue["expected_worktrees"] == []
    assert Enum.map(queue["items"], & &1["status"]) == ["completed"]
    Store.flush(reopened)
  end

  test "persists a stopped queue resume in Bedrock" do
    project = Hancho.Project.new(temporary_directory())
    items = [%{position: 0, issue_id: "task-1", run_id: "queue-resume-001"}]
    state = %{repository: project.root, branch: "main", head: "head-0"}

    assert {:ok, store} = Store.open(project.bedrock_path)

    assert :ok =
             Store.create_queue(
               store,
               "queue-resume",
               "implement",
               "beadwork-ready",
               items,
               state
             )

    assert :ok = Store.start_queue_item(store, "queue-resume", 0)
    assert :ok = Store.stop_queue_item(store, "queue-resume", 0, :agent_stopped)
    assert :ok = Store.resume_queue(store, "queue-resume")
    assert {:ok, queue} = Store.fetch_queue(store, "queue-resume")
    assert queue["status"] == "running"
    assert hd(queue["items"])["status"] == "running"
    assert queue["error"] == nil
    Store.flush(store)
  end

  test "reconciles real Git and worktree state and reports exact mismatches" do
    repository = temporary_repository()
    {:ok, root} = Hancho.Git.repository_root(working_dir: repository)
    project = Hancho.Project.new(root)
    File.mkdir_p!(project.worktrees_path)

    assert {:ok, initial} = QueueReconciler.initial(project)

    queue = %{
      "expected_branch" => initial.branch,
      "expected_head" => initial.head,
      "expected_worktrees" => initial.expected_worktrees
    }

    assert {:ok, %{worktrees: []}} = QueueReconciler.before_item(project, queue)

    unexpected = Path.join(project.worktrees_path, "unexpected")
    File.mkdir_p!(unexpected)

    assert {:error,
            %{
              code: "filesystem_out_of_sync",
              field: "worktree_directories",
              expected: [],
              actual: [^unexpected]
            }} = QueueReconciler.before_item(project, queue)
  end

  test "uses retained Hancho worktrees as the queue baseline" do
    repository = temporary_repository()
    {:ok, root} = Hancho.Git.repository_root(working_dir: repository)
    project = Hancho.Project.new(root)
    File.mkdir_p!(project.worktrees_path)
    {:ok, head} = Hancho.Git.head(working_dir: root)
    path = Path.join(project.worktrees_path, "retained-run")

    assert {:ok, :done} = Hancho.Git.create_worktree(root, path, head)
    File.write!(Path.join(path, "retained.txt"), "diagnostic evidence\n")

    assert {:ok, initial} = QueueReconciler.initial(project)

    assert initial.worktrees == [path]
    assert initial.expected_worktrees == [%{path: path, head: head, clean: false}]

    queue = %{
      "expected_branch" => initial.branch,
      "expected_head" => initial.head,
      "expected_worktrees" => initial.expected_worktrees
    }

    assert {:ok, %{worktrees: [^path]}} = QueueReconciler.before_item(project, queue)
  end

  test "reconciles a retained stopped-run worktree against durable outputs" do
    repository = temporary_repository()
    {:ok, root} = Hancho.Git.repository_root(working_dir: repository)
    project = Hancho.Project.new(root)
    File.mkdir_p!(project.worktrees_path)
    assert {:ok, initial} = QueueReconciler.initial(project)

    queue = %{
      "expected_branch" => initial.branch,
      "expected_head" => initial.head,
      "expected_worktrees" => initial.expected_worktrees
    }

    path = Path.join(project.worktrees_path, "queue-real-001")

    assert {:ok, :done} = Hancho.Git.create_worktree(root, path, initial.head)

    artifacts = %{
      "worktree_created" => %{"worktree_path" => path, "baseline" => initial.head}
    }

    assert {:ok, %{worktrees: [^path]}} = QueueReconciler.after_run(project, queue, artifacts)

    File.rm_rf!(path)

    assert {:error, %{code: "filesystem_out_of_sync", field: "worktree_directories"}} =
             QueueReconciler.after_run(project, queue, artifacts)
  end

  test "accepts expected dirty state after a stopped in-place run" do
    repository = temporary_repository()
    project = Hancho.Project.new(repository)
    assert {:ok, initial} = QueueReconciler.initial(project)

    queue = %{
      "expected_branch" => initial.branch,
      "expected_head" => initial.head,
      "expected_worktrees" => initial.expected_worktrees
    }

    artifacts = %{
      "workspace_opened" => %{
        "mode" => "in_place",
        "workspace_path" => repository,
        "baseline" => initial.head
      }
    }

    File.write!(Path.join(repository, "agent-change.txt"), "retained work\n")

    assert {:ok, summary} =
             QueueReconciler.after_stopped_run(project, queue, artifacts)

    refute summary.clean
    assert summary.changed_paths == ["agent-change.txt"]

    assert {:error, %{code: "filesystem_out_of_sync", field: "repository_status"}} =
             QueueReconciler.after_run(project, queue, artifacts)
  end

  test "validates saved main and retained-worktree state before retry" do
    repository = temporary_repository()
    project = Hancho.Project.new(repository)
    File.mkdir_p!(project.worktrees_path)
    {:ok, head} = Hancho.Git.head(working_dir: repository)
    path = Path.join(project.worktrees_path, "run-retry")
    assert {:ok, :done} = Hancho.Git.create_worktree(repository, path, head)
    File.write!(Path.join(path, "feature.txt"), "retained work\n")

    outputs = %{
      "repository_guard" => %{"baseline" => head, "branch" => "main"},
      "isolate" => %{"baseline" => head, "worktree_path" => path}
    }

    {:ok, definition} =
      Hancho.Workflow.Definition.new(%{
        name: "retry",
        version: 1,
        steps: [
          %{name: "repository_guard", action: "Hancho.Actions.Preflight", params: %{}},
          %{name: "isolate", action: "Hancho.Actions.CreateWorktree", params: %{}}
        ]
      })

    assert {:ok, %{head: ^head}} = RunReconciler.retry(project, outputs, definition: definition)

    File.write!(Path.join(repository, "unexpected.txt"), "changed\n")

    assert {:error, %{code: "filesystem_out_of_sync", field: "repository_status"}} =
             RunReconciler.retry(project, outputs, definition: definition)
  end

  test "keeps the main repository at baseline while it retries an unlanded worktree commit" do
    repository = temporary_repository()
    {:ok, repository} = Hancho.Git.repository_root(working_dir: repository)
    project = Hancho.Project.new(repository)
    File.mkdir_p!(project.worktrees_path)
    {:ok, baseline} = Hancho.Git.head(working_dir: repository)
    path = Path.join(project.worktrees_path, "run-retry-land")
    assert {:ok, :done} = Hancho.Git.create_worktree(repository, path, baseline)

    File.write!(Path.join(path, "feature.txt"), "retained commit\n")
    {_output, 0} = System.cmd("git", ["-C", path, "add", "feature.txt"])

    {_output, 0} =
      System.cmd("git", [
        "-C",
        path,
        "-c",
        "user.name=Hancho Test",
        "-c",
        "user.email=hancho@example.test",
        "commit",
        "-m",
        "feat: retain worktree commit"
      ])

    {:ok, commit} = Hancho.Git.head(working_dir: path)
    refute commit == baseline

    outputs = %{
      "preflight" => %{"baseline" => baseline, "branch" => "main"},
      "create_worktree" => %{"baseline" => baseline, "worktree_path" => path},
      "commit" => %{"commit" => commit, "issue_id" => "task-1"}
    }

    {:ok, definition} =
      Hancho.Workflow.Definition.new(%{
        name: "retry-land",
        version: 1,
        steps: [
          %{name: "preflight", action: "Hancho.Actions.Preflight", params: %{}},
          %{
            name: "create_worktree",
            action: "Hancho.Actions.CreateWorktree",
            params: %{}
          },
          %{name: "commit", action: "Hancho.Actions.Commit", params: %{}},
          %{name: "land", action: "Hancho.Actions.Land", params: %{}}
        ]
      })

    assert {:ok, %{head: ^baseline}} =
             RunReconciler.retry(project, outputs, definition: definition)

    artifacts = Hancho.Workflow.Artifacts.from_outputs(definition, outputs)

    queue = %{
      "expected_branch" => "main",
      "expected_head" => baseline,
      "expected_worktrees" => []
    }

    assert {:ok, %{head: ^baseline, worktrees: [^path]}} =
             QueueReconciler.after_stopped_run(project, queue, artifacts)

    assert {:ok, _result} = Hancho.Git.merge_ff_only(repository, commit)

    assert {:ok, %{head: ^commit}} =
             RunReconciler.retry(project, outputs, definition: definition)

    assert {:ok, %{head: ^commit, worktrees: [^path]}} =
             QueueReconciler.after_stopped_run(project, queue, artifacts)
  end

  test "allows a stopped in-place run to retry with retained changes" do
    repository = temporary_repository()
    project = Hancho.Project.new(repository)
    {:ok, head} = Hancho.Git.head(working_dir: repository)

    outputs = %{
      "repository_guard" => %{"baseline" => head, "branch" => "main"},
      "workspace" => %{
        "mode" => "in_place",
        "workspace_path" => repository,
        "baseline" => head
      }
    }

    {:ok, definition} =
      Hancho.Workflow.Definition.new(%{
        name: "retry-in-place",
        version: 1,
        steps: [
          %{name: "repository_guard", action: "Hancho.Actions.Preflight", params: %{}},
          %{name: "workspace", action: "Hancho.Actions.UseRepository", params: %{}}
        ]
      })

    File.write!(Path.join(repository, "agent-change.txt"), "retained work\n")

    assert {:ok, summary} = RunReconciler.retry(project, outputs, definition: definition)
    refute summary.clean
    assert summary.changed_paths == ["agent-change.txt"]

    committed_outputs =
      Map.put(outputs, "commit", %{"commit" => head, "issue_id" => "task-1"})

    {:ok, committed_definition} =
      Hancho.Workflow.Definition.new(%{
        name: "retry-in-place-committed",
        version: 1,
        steps:
          definition.steps ++
            [%{name: "commit", action: "Hancho.Actions.Commit", params: %{}}]
      })

    assert {:error, %{code: "filesystem_out_of_sync", field: "repository_status"}} =
             RunReconciler.retry(project, committed_outputs, definition: committed_definition)
  end

  test "stops reconciliation when the main repository becomes dirty" do
    repository = temporary_repository()
    {:ok, root} = Hancho.Git.repository_root(working_dir: repository)
    project = Hancho.Project.new(root)
    assert {:ok, initial} = QueueReconciler.initial(project)

    queue = %{
      "expected_branch" => initial.branch,
      "expected_head" => initial.head,
      "expected_worktrees" => initial.expected_worktrees
    }

    File.write!(Path.join(root, "unexpected.txt"), "changed\n")

    assert {:error,
            %{
              code: "filesystem_out_of_sync",
              field: "repository_status",
              expected: "clean"
            }} = QueueReconciler.before_item(project, queue)
  end

  defp temporary_directory do
    path = Path.join(System.tmp_dir!(), "hancho-queue-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)

    on_exit(fn ->
      Hancho.State.Bedrock.reset()
      File.rm_rf!(path)
    end)

    path
  end

  defp create_completed_child(store, run_id, commit) do
    yaml = """
    name: implement
    version: 1
    steps:
      - name: land
        action: Hancho.Actions.Land
        params: {}
    """

    source = %{
      path: "implement.yaml",
      yaml: yaml,
      sha256: :crypto.hash(:sha256, yaml) |> Base.encode16(case: :lower)
    }

    with {:ok, values} <- YamlElixir.read_from_string(yaml),
         {:ok, definition} <- Hancho.Workflow.Definition.new(values),
         :ok <- Store.create_run(store, run_id, definition, %{"issue_id" => "task-1"}, source),
         :ok <- Store.start_step(store, run_id, 0, hd(definition.steps), %{}),
         output = %{"commit" => commit, "branch" => "main"},
         :ok <- Store.complete_step(store, run_id, 0, output, %{}),
         :ok <- Store.complete_run(store, run_id, %{"land" => output}) do
      :ok
    end
  end

  defp temporary_repository do
    path = temporary_directory()
    {_output, 0} = System.cmd("git", ["init", "--initial-branch=main", path])
    File.write!(Path.join(path, ".gitignore"), "/.hancho/\n")
    {_output, 0} = System.cmd("git", ["-C", path, "add", ".gitignore"])

    {_output, 0} =
      System.cmd("git", [
        "-C",
        path,
        "-c",
        "user.name=Hancho Test",
        "-c",
        "user.email=hancho@example.test",
        "commit",
        "-m",
        "chore: initialize repository"
      ])

    path
  end

  defp read_events(path) do
    path
    |> File.stream!()
    |> Enum.map(&Jason.decode!/1)
  end
end
