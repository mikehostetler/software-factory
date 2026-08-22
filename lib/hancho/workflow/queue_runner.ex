defmodule Hancho.Workflow.QueueRunner do
  @moduledoc "Runs a durable workflow queue serially in the foreground."

  alias Hancho.Beadwork.Issue
  alias Hancho.Forensics

  alias Hancho.Workflow.{
    Compiler,
    IssueSelector,
    Loader,
    QueuePlan,
    QueueReconciler,
    QueueReporter,
    Runner,
    Store
  }

  @source "beadwork-ready"

  @spec run(Hancho.Project.t(), String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, QueueResult.t()} | {:error, term()}
  def run(project, workflow, source, count, options \\ []) do
    lease_options = Keyword.put_new(options, :lease_command, "queue #{workflow}")

    Hancho.FactoryLease.with_lease(project, lease_options, fn ->
      do_run(project, workflow, source, count, options)
    end)
  end

  defp do_run(project, workflow, source, count, options) do
    beadwork = Keyword.get(options, :beadwork, Hancho.Beadwork)
    issue_selector = Keyword.get(options, :issue_selector, IssueSelector)
    store_api = Keyword.get(options, :store_api, Store)
    reconciler = Keyword.get(options, :reconciler, QueueReconciler)

    with :ok <- validate_request(source, count),
         {:ok, issues} <- issue_selector.select(beadwork, project.root, count),
         queue_id = Keyword.get_lazy(options, :queue_id, &new_queue_id/0),
         items = QueuePlan.build(queue_id, issues),
         {:ok, repository_state} <- reconciler.initial(project, reconcile_options(options)),
         {:ok, store} <- store_api.open(project.bedrock_path) do
      run_with_store(
        project,
        workflow,
        source,
        items,
        queue_id,
        repository_state,
        store,
        options
      )
    end
  end

  @spec resume(Hancho.Project.t(), String.t(), keyword()) ::
          {:ok, QueueResult.t()} | {:error, term()}
  def resume(project, queue_id, options \\ []) do
    lease_options = Keyword.put_new(options, :lease_command, "resume #{queue_id}")

    Hancho.FactoryLease.with_lease(project, lease_options, fn ->
      do_resume(project, queue_id, options)
    end)
  end

  defp do_resume(project, queue_id, options) do
    store_api = Keyword.get(options, :store_api, Store)

    with {:ok, store} <- store_api.open(project.bedrock_path) do
      resume_with_store(project, queue_id, store, options)
    end
  end

  @spec preview(Hancho.Project.t(), String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def preview(project, workflow, source, count, options \\ []) do
    beadwork = Keyword.get(options, :beadwork, Hancho.Beadwork)
    issue_selector = Keyword.get(options, :issue_selector, IssueSelector)
    reconciler = Keyword.get(options, :reconciler, QueueReconciler)
    loader = Keyword.get(options, :loader, Loader)
    compiler = Keyword.get(options, :compiler, Compiler)

    with :ok <- validate_request(source, count),
         {:ok, issues} <- issue_selector.select(beadwork, project.root, count),
         {:ok, repository} <- reconciler.initial(project, reconcile_options(options)),
         {:ok, definition} <- loader.load(project, workflow),
         {:ok, compilation} <-
           compiler.compile(
             project,
             definition,
             %{"repo_path" => project.root, "issue_id" => hd(issues).id},
             options
           ) do
      {:ok,
       %{
         workflow: workflow,
         source: source,
         issues:
           Enum.map(issues, fn issue ->
             issue
             |> Issue.to_map()
             |> Map.take(["id", "title", "status"])
             |> Map.reject(fn {_key, value} -> is_nil(value) end)
           end),
         repository: %{
           branch: repository.branch,
           head: repository.head,
           clean: true,
           worktrees: repository.worktrees
         },
         settings: workflow_settings(definition),
         compilation: compilation
       }}
    end
  end

  defp workflow_settings(definition) do
    implement = Enum.find(definition.steps, &(&1.action == "Hancho.Actions.Implement"))
    verify = Enum.find(definition.steps, &(&1.action == "Hancho.Actions.Verify"))
    implement_params = resolved_params(definition, implement)

    %{
      provider: param(implement_params, "provider"),
      model: param(implement_params, "model"),
      reasoning_effort: param(implement_params, "reasoning_effort"),
      implementation_timeout_ms: param(implement_params, "timeout_ms"),
      verification_timeout_ms: step_param(verify, "timeout_ms"),
      repairs:
        definition.steps
        |> Enum.filter(& &1.on_error)
        |> Enum.map(fn step ->
          %{
            step: step.name,
            provider: step.on_error.repair_with,
            max_attempts: step.on_error.max_attempts,
            codes: step.on_error.codes
          }
        end)
    }
  end

  defp step_param(nil, _name), do: nil
  defp step_param(step, name), do: Map.get(step.params, name)

  defp resolved_params(_definition, nil), do: %{}

  defp resolved_params(definition, step),
    do: Hancho.Workflow.RoleResolver.params(definition, step)

  defp param(params, name) do
    Enum.find_value(params, fn {key, value} -> if to_string(key) == name, do: value end)
  end

  defp run_with_store(
         project,
         workflow,
         source,
         items,
         queue_id,
         repository_state,
         store,
         options
       ) do
    store_api = Keyword.get(options, :store_api, Store)

    with :ok <-
           store_api.create_queue(
             store,
             queue_id,
             workflow,
             source,
             items,
             repository_state
           ),
         :ok <- store_api.flush(store),
         :ok <-
           QueueReporter.emit(
             project,
             queue_id,
             "queue.started",
             "Queue #{queue_id} selected #{length(items)} tasks.",
             %{workflow: workflow, source: source, issues: Enum.map(items, & &1.issue_id)},
             true,
             options
           ) do
      run_items(project, workflow, queue_id, items, 0, store, options)
    end
  end

  defp resume_with_store(project, queue_id, store, options) do
    store_api = Keyword.get(options, :store_api, Store)
    runner = Keyword.get(options, :workflow_runner, Runner)

    with {:ok, queue} <- store_api.fetch_queue(store, queue_id),
         :ok <- resumable_queue(queue),
         items = QueuePlan.from_state(queue),
         position = queue["current_position"],
         item = Enum.at(items, position),
         {:ok, recovery} <- child_recovery(store_api, store, item.run_id),
         :ok <- store_api.resume_queue(store, queue_id),
         :ok <- store_api.flush(store),
         :ok <-
           QueueReporter.emit(
             project,
             queue_id,
             "queue.resumed",
             "Queue #{queue_id} resumed at #{item.issue_id}.",
             QueueReporter.item_metadata(item, position, length(items)),
             true,
             options
           ),
         :ok <-
           QueueReporter.emit(
             project,
             queue_id,
             recovery_event(recovery),
             QueueReporter.item_message(recovery_verb(recovery), item, position, length(items)),
             QueueReporter.item_metadata(item, position, length(items))
             |> Map.put(:recovery, recovery),
             true,
             options
           ) do
      child_options =
        options
        |> Keyword.put(:run_id, item.run_id)
        |> Keyword.put(:factory_lease, :held)

      case recover_child(runner, recovery, project, queue["workflow_name"], item, child_options) do
        {:ok, %{status: :completed} = result} ->
          complete_item(
            project,
            queue["workflow_name"],
            queue_id,
            items,
            position,
            item,
            result,
            store,
            options
          )

        {:ok, %{status: :stopped} = result} ->
          stop_item(
            project,
            queue["workflow_name"],
            queue_id,
            items,
            position,
            item,
            result,
            store,
            options
          )

        {:error, reason} ->
          stop_for_error(
            project,
            queue["workflow_name"],
            queue_id,
            items,
            position,
            item,
            %{
              code: "child_recovery_failed",
              recovery: recovery,
              error: Hancho.Log.Event.normalize(reason)
            },
            store,
            options
          )
      end
    end
  end

  defp run_items(project, workflow, queue_id, items, position, store, options)
       when position == length(items) do
    store_api = Keyword.get(options, :store_api, Store)

    with :ok <- store_api.complete_queue(store, queue_id),
         :ok <- store_api.flush(store),
         {:ok, result} <- QueueReporter.result(store_api, store, queue_id, workflow),
         :ok <-
           QueueReporter.emit(
             project,
             queue_id,
             "queue.completed",
             "Queue #{queue_id} completed #{length(items)}/#{length(items)} tasks.",
             %{
               completed_count: length(items),
               total_count: length(items),
               elapsed_ms: result.elapsed_ms,
               task_summaries: result.task_summaries,
               usage_summary: result.usage_summary
             },
             true,
             options
           ) do
      {:ok, result}
    end
  end

  defp run_items(project, workflow, queue_id, items, position, store, options) do
    store_api = Keyword.get(options, :store_api, Store)
    reconciler = Keyword.get(options, :reconciler, QueueReconciler)
    runner = Keyword.get(options, :workflow_runner, Runner)
    item = Enum.at(items, position)

    with {:ok, queue} <- store_api.fetch_queue(store, queue_id),
         {:ok, summary} <- reconciler.before_item(project, queue, reconcile_options(options)),
         :ok <-
           QueueReporter.reconciliation(
             project,
             queue_id,
             "before",
             position,
             item,
             summary,
             options
           ),
         :ok <- store_api.start_queue_item(store, queue_id, position),
         :ok <- store_api.flush(store),
         :ok <-
           QueueReporter.emit(
             project,
             queue_id,
             "queue.item_started",
             QueueReporter.item_message("Starting", item, position, length(items)),
             QueueReporter.item_metadata(item, position, length(items)),
             true,
             options
           ) do
      child_options =
        options
        |> Keyword.put(:run_id, item.run_id)
        |> Keyword.put(:factory_lease, :held)

      case runner.run(
             project,
             workflow,
             %{"repo_path" => project.root, "issue_id" => item.issue_id},
             child_options
           ) do
        {:ok, %{status: :completed} = result} ->
          complete_item(
            project,
            workflow,
            queue_id,
            items,
            position,
            item,
            result,
            store,
            options
          )

        {:ok, %{status: :stopped} = result} ->
          stop_item(project, workflow, queue_id, items, position, item, result, store, options)

        {:error, reason} ->
          stop_for_error(
            project,
            workflow,
            queue_id,
            items,
            position,
            item,
            %{code: "child_run_failed", error: Hancho.Log.Event.normalize(reason)},
            store,
            options
          )
      end
    else
      {:error, reason} ->
        stop_for_error(
          project,
          workflow,
          queue_id,
          items,
          position,
          item,
          reason,
          store,
          options
        )
    end
  end

  defp complete_item(
         project,
         workflow,
         queue_id,
         items,
         position,
         item,
         result,
         store,
         options
       ) do
    store_api = Keyword.get(options, :store_api, Store)
    reconciler = Keyword.get(options, :reconciler, QueueReconciler)

    with {:ok, queue} <- store_api.fetch_queue(store, queue_id),
         {:ok, summary} <-
           reconciler.after_run(project, queue, result.artifacts, reconcile_options(options)),
         :ok <-
           QueueReporter.reconciliation(
             project,
             queue_id,
             "after",
             position,
             item,
             summary,
             options
           ),
         landed when is_binary(landed) <- get_in(result.artifacts, ["landing", "commit"]),
         :ok <- store_api.complete_queue_item(store, queue_id, position, landed),
         :ok <- store_api.flush(store),
         :ok <-
           QueueReporter.emit(
             project,
             queue_id,
             "queue.item_completed",
             QueueReporter.item_message("Completed", item, position, length(items)),
             QueueReporter.item_metadata(item, position, length(items)) |> Map.put(:head, landed),
             true,
             options
           ) do
      run_items(project, workflow, queue_id, items, position + 1, store, options)
    else
      nil ->
        stop_for_error(
          project,
          workflow,
          queue_id,
          items,
          position,
          item,
          %{code: "missing_landed_commit"},
          store,
          options
        )

      {:error, reason} ->
        stop_for_error(
          project,
          workflow,
          queue_id,
          items,
          position,
          item,
          reason,
          store,
          options
        )
    end
  end

  defp stop_item(
         project,
         workflow,
         queue_id,
         items,
         position,
         item,
         result,
         store,
         options
       ) do
    store_api = Keyword.get(options, :store_api, Store)
    reconciler = Keyword.get(options, :reconciler, QueueReconciler)

    workflow_error = %{
      code: "workflow_stopped",
      step: result.current_step,
      error: result.error,
      child_forensic_report: result.forensic_report
    }

    error =
      case store_api.fetch_queue(store, queue_id) do
        {:ok, queue} ->
          case reconcile_stopped(
                 reconciler,
                 project,
                 queue,
                 result.artifacts,
                 reconcile_options(options)
               ) do
            {:ok, summary} ->
              :ok =
                QueueReporter.reconciliation(
                  project,
                  queue_id,
                  "after",
                  position,
                  item,
                  summary,
                  options
                )

              workflow_error

            {:error, reason} ->
              Map.put(workflow_error, :reconciliation, %{
                status: "failed",
                error: Hancho.Log.Event.normalize(reason)
              })
          end

        {:error, reason} ->
          Map.put(workflow_error, :queue_state, %{
            status: "unavailable",
            error: Hancho.Log.Event.normalize(reason)
          })
      end

    stop_for_error(
      project,
      workflow,
      queue_id,
      items,
      position,
      item,
      error,
      store,
      options
    )
  end

  defp with_queue_forensics(project, workflow, queue_id, items, position, item, error, options) do
    forensics = Keyword.get(options, :forensics, Forensics)
    child_report = error_field(error, :child_forensic_report)

    details = %{
      queue_id: queue_id,
      workflow: workflow,
      issue_id: item.issue_id,
      child_run_id: item.run_id,
      position: position,
      total_count: length(items),
      error: error,
      child_forensic_report: child_report
    }

    case forensics.capture_queue(project, details, options) do
      {:ok, path} ->
        put_error_field(error, :forensic_report, path)

      {:error, reason} ->
        Hancho.Log.internal(:warning, "Failed to write queue forensic report",
          queue_id: queue_id,
          error: inspect(reason)
        )

        error
    end
  end

  defp stop_for_error(
         project,
         workflow,
         queue_id,
         items,
         position,
         item,
         error,
         store,
         options
       ) do
    store_api = Keyword.get(options, :store_api, Store)

    error =
      with_queue_forensics(project, workflow, queue_id, items, position, item, error, options)

    event = if out_of_sync?(error), do: "queue.reconciliation_failed", else: "queue.stopped"

    message =
      QueueReporter.item_message("Stopped", item, position, length(items)) <>
        ": #{inspect(error)}"

    with :ok <- store_api.stop_queue_item(store, queue_id, position, error),
         :ok <- store_api.flush(store),
         :ok <-
           QueueReporter.emit(
             project,
             queue_id,
             event,
             message,
             Map.put(QueueReporter.item_metadata(item, position, length(items)), :error, error),
             true,
             options
           ) do
      QueueReporter.result(store_api, store, queue_id, workflow)
    end
  end

  defp resumable_queue(%{"status" => status, "items" => items, "current_position" => position})
       when status in ["stopped", "running", "recovery_required"] do
    case Enum.at(items, position) do
      %{"status" => item_status} when item_status in ["pending", "stopped", "running"] -> :ok
      _item -> {:error, :resumable_queue_item_not_found}
    end
  end

  defp resumable_queue(%{"status" => status}), do: {:error, {:queue_not_resumable, status}}

  defp child_recovery(store_api, store, run_id) do
    if function_exported?(store_api, :fetch_run, 2) do
      case store_api.fetch_run(store, run_id) do
        {:ok, _run} -> {:ok, :retry}
        {:error, :not_found} -> {:ok, :start}
        {:error, reason} -> {:error, {:child_state_unavailable, reason}}
      end
    else
      {:ok, :retry}
    end
  end

  defp recover_child(runner, :retry, project, _workflow, item, options) do
    runner.retry(project, item.run_id, options)
  end

  defp recover_child(runner, :start, project, workflow, item, options) do
    runner.run(
      project,
      workflow,
      %{"repo_path" => project.root, "issue_id" => item.issue_id},
      options
    )
  end

  defp recovery_event(:retry), do: "queue.item_retried"
  defp recovery_event(:start), do: "queue.item_restarted"
  defp recovery_verb(:retry), do: "Retrying"
  defp recovery_verb(:start), do: "Restarting"

  defp reconcile_stopped(reconciler, project, queue, artifacts, options) do
    if function_exported?(reconciler, :after_stopped_run, 4) do
      reconciler.after_stopped_run(project, queue, artifacts, options)
    else
      reconciler.after_run(project, queue, artifacts, options)
    end
  end

  defp validate_request(@source, count) when is_integer(count) and count > 0, do: :ok

  defp validate_request(source, _count) when source != @source,
    do: {:error, "Unknown queue source: #{source}"}

  defp validate_request(_source, _count), do: {:error, "Queue count must be a positive integer."}

  defp reconcile_options(options), do: Keyword.take(options, [:git])

  defp out_of_sync?(%{code: "filesystem_out_of_sync"}), do: true
  defp out_of_sync?(%{"code" => "filesystem_out_of_sync"}), do: true

  defp out_of_sync?(error) when is_map(error) do
    error
    |> error_field(:reconciliation)
    |> error_field(:error)
    |> out_of_sync?()
  end

  defp out_of_sync?(_error), do: false

  defp error_field(nil, _key), do: nil

  defp error_field(error, key) when is_map(error) do
    Map.get(error, key, Map.get(error, Atom.to_string(key)))
  end

  defp error_field(_error, _key), do: nil

  defp put_error_field(error, key, value) when is_map(error), do: Map.put(error, key, value)

  defp put_error_field(error, key, value) do
    %{code: "queue_stopped", error: Hancho.Log.Event.normalize(error)}
    |> Map.put(key, value)
  end

  defp new_queue_id do
    suffix = :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
    "queue-#{System.system_time(:millisecond)}-#{suffix}"
  end
end
