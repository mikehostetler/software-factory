defmodule Hancho.Workflow.Runner do
  @moduledoc "Runs one workflow in the foreground."

  alias Hancho.Workflow.{
    Artifacts,
    Compiler,
    Definition,
    FailureCleanup,
    Loader,
    Repair,
    Result,
    RunReconciler,
    Runtime,
    Store
  }

  alias Hancho.Forensics

  @spec run(Hancho.Project.t(), String.t(), map(), keyword()) ::
          {:ok, Hancho.Workflow.Result.t()} | {:error, term()}
  def run(project, workflow_name, input, options \\ []) do
    lease_options = Keyword.put_new(options, :lease_command, "run #{workflow_name}")

    Hancho.FactoryLease.with_lease(project, lease_options, fn ->
      do_run(project, workflow_name, input, options)
    end)
  end

  defp do_run(project, workflow_name, input, options) do
    loader = Keyword.get(options, :loader, Loader)
    store_api = Keyword.get(options, :store_api, Store)
    compiler = Keyword.get(options, :compiler, Compiler)

    with {:ok, definition, workflow_source} <- loader.load_with_source(project, workflow_name),
         {:ok, _compiled} <- compiler.compile(project, definition, input, options),
         {:ok, store} <- store_api.open(project.bedrock_path) do
      result = run_with_store(project, definition, workflow_source, input, store, options)

      case flush_store(store_api, store, options) do
        :ok -> result
        {:error, reason} -> state_flush_error(result, reason)
      end
    end
  end

  @spec retry(Hancho.Project.t(), String.t(), keyword()) ::
          {:ok, Hancho.Workflow.Result.t()} | {:error, term()}
  def retry(project, run_id, options \\ []) do
    lease_options = Keyword.put_new(options, :lease_command, "retry #{run_id}")

    Hancho.FactoryLease.with_lease(project, lease_options, fn ->
      do_retry(project, run_id, options)
    end)
  end

  defp do_retry(project, run_id, options) do
    store_api = Keyword.get(options, :store_api, Store)

    with {:ok, store} <- store_api.open(project.bedrock_path) do
      result = retry_with_store(project, run_id, store, options)

      case flush_store(store_api, store, options) do
        :ok -> result
        {:error, reason} -> state_flush_error(result, reason)
      end
    end
  end

  defp run_with_store(project, definition, workflow_source, input, store, options) do
    run_id = Keyword.get_lazy(options, :run_id, &new_run_id/0)
    store_api = Keyword.get(options, :store_api, Store)

    with_audit_log(project, run_id, options, fn log ->
      with :ok <- store_api.create_run(store, run_id, definition, input, workflow_source),
           :ok <- log_workflow_source(log, definition, workflow_source),
           {:ok, result} <- run_runtime(definition, input, run_id, store, log, options) do
        {:ok, attach_failure_evidence(project, result, store, options)}
      end
    end)
  end

  defp retry_with_store(project, run_id, store, options) do
    store_api = Keyword.get(options, :store_api, Store)
    reconciler = Keyword.get(options, :reconciler, RunReconciler)
    compiler = Keyword.get(options, :compiler, Compiler)

    with {:ok, run} <- store_api.fetch_run(store, run_id),
         :ok <- resumable_run(run),
         {:ok, definition} <- definition_from_snapshot(run),
         {:ok, input} <- Jason.decode(run["input_json"]),
         {:ok, _compiled} <- compiler.compile(project, definition, input, options),
         {:ok, steps} <- store_api.list_steps(store, run_id),
         {:ok, recovery} <- recovery_action(steps),
         {:ok, outputs} <- completed_outputs(steps),
         {:ok, repairs} <- Repair.from_steps(steps) do
      case reconciler.retry(
             project,
             outputs,
             Keyword.put(reconcile_options(options), :definition, definition)
           ) do
        {:ok, _summary} ->
          recover_run(
            project,
            definition,
            input,
            run_id,
            store,
            outputs,
            repairs,
            recovery,
            options
          )

        {:error, reason} ->
          reconciliation_failure(
            project,
            run,
            definition,
            outputs,
            repairs,
            recovery,
            store,
            reason,
            options
          )
      end
    end
  end

  defp reconciliation_failure(
         project,
         run,
         definition,
         outputs,
         repairs,
         recovery,
         store,
         reason,
         options
       ) do
    run_id = run["id"]
    step = recovery_step(run, definition, recovery)

    error = %{
      code: "recovery_reconciliation_failed",
      step: step,
      error: Hancho.Log.Event.normalize(reason)
    }

    store_api = Keyword.get(options, :store_api, Store)
    artifacts = definition |> Artifacts.from_outputs(outputs) |> put_repairs(repairs)

    with_audit_log(project, run_id, options, fn log ->
      with :ok <- persist_recovery_andon(store_api, store, run_id, recovery, step, error),
           :ok <-
             Hancho.Audit.write(log, "Workflow recovery Andon: repository state is not safe",
               event: "workflow.recovery_andon",
               level: :error,
               metadata: error
             ),
           {:ok, result} <-
             Result.new(%{
               run_id: run_id,
               workflow: definition.name,
               status: :stopped,
               current_step: step,
               outputs: outputs,
               artifacts: artifacts,
               error: error
             }) do
        {:ok, attach_failure_evidence(project, result, store, options)}
      end
    end)
  end

  defp persist_recovery_andon(store_api, store, run_id, {:retry, position}, step, error) do
    store_api.mark_recovery_required(store, run_id, position, step, error)
  end

  defp persist_recovery_andon(store_api, store, run_id, :finalize, step, error) do
    store_api.mark_run_recovery_required(store, run_id, step, error)
  end

  defp recovery_step(_run, definition, {:retry, position}),
    do: Enum.at(definition.steps, position).name

  defp recovery_step(run, _definition, :finalize), do: run["current_step"]

  defp recover_run(
         project,
         definition,
         input,
         run_id,
         store,
         outputs,
         repairs,
         {:retry, position},
         options
       ) do
    store_api = Keyword.get(options, :store_api, Store)

    with_audit_log(project, run_id, options, fn log ->
      with :ok <- store_api.retry_run(store, run_id, position),
           :ok <-
             Hancho.Audit.write(log, "Workflow retry started",
               event: "workflow.retry_started",
               metadata: %{step: Enum.at(definition.steps, position).name}
             ),
           {:ok, result} <-
             run_runtime(definition, input, run_id, store, log, options, %{
               index: position,
               outputs: outputs,
               artifacts: definition |> Artifacts.from_outputs(outputs) |> put_repairs(repairs),
               repairs: repairs
             }) do
        {:ok, attach_failure_evidence(project, result, store, options)}
      end
    end)
  end

  defp recover_run(
         project,
         definition,
         _input,
         run_id,
         store,
         outputs,
         repairs,
         :finalize,
         options
       ) do
    store_api = Keyword.get(options, :store_api, Store)
    artifacts = definition |> Artifacts.from_outputs(outputs) |> put_repairs(repairs)

    with_audit_log(project, run_id, options, fn log ->
      with :ok <- store_api.complete_run(store, run_id, outputs),
           :ok <-
             Hancho.Audit.write(log, "Workflow recovery completed",
               event: "workflow.recovery_completed"
             ),
           {:ok, result} <-
             Result.new(%{
               run_id: run_id,
               workflow: definition.name,
               status: :completed,
               current_step: nil,
               outputs: outputs,
               artifacts: artifacts,
               error: nil
             }) do
        {:ok, attach_failure_evidence(project, result, store, options)}
      end
    end)
  end

  defp run_runtime(definition, input, run_id, store, log, options, resume \\ %{}) do
    arguments =
      Map.merge(
        %{
          definition: definition,
          input: Hancho.Log.Event.normalize(input),
          run_id: run_id,
          store: store,
          store_api: Keyword.get(options, :store_api, Store),
          registry: Keyword.get(options, :registry, Hancho.Workflow.Registry),
          executor: Keyword.get(options, :executor, Hancho.Workflow.Executor),
          services: Keyword.get(options, :services, %{}),
          verbose: Keyword.get(options, :verbose, false),
          log: log
        },
        resume
      )

    with {:ok, pid} <- Runtime.start_link(arguments) do
      {:ok, Runtime.run(pid)}
    end
  end

  defp with_audit_log(project, run_id, options, function) do
    with {:ok, log} <- open_log(project, run_id, options) do
      try do
        function.(log)
      after
        Hancho.Audit.close(log)
      end
    end
  end

  defp open_log(project, run_id, options) do
    case Keyword.get(options, :log) do
      :disabled ->
        {:ok, :disabled}

      _other ->
        Hancho.Audit.open(project, metadata: %{run_id: run_id})
    end
  end

  defp flush_store(store_api, store, options) do
    if Keyword.get(options, :flush_state, true) do
      store_api.flush(store)
    else
      :ok
    end
  end

  defp state_flush_error({:ok, result}, reason) do
    {:error,
     %{
       code: "state_flush_failed",
       run_id: result.run_id,
       status: result.status,
       current_step: result.current_step,
       error: Hancho.Log.Event.normalize(result.error),
       cleanup: Hancho.Log.Event.normalize(result.cleanup),
       forensic_report: result.forensic_report,
       flush_error: Hancho.Log.Event.normalize(reason)
     }}
  end

  defp state_flush_error(result, reason) do
    {:error,
     %{
       code: "state_flush_failed",
       result: Hancho.Log.Event.normalize(result),
       flush_error: Hancho.Log.Event.normalize(reason)
     }}
  end

  defp resumable_run(%{"status" => status})
       when status in ["stopped", "running", "recovery_required"],
       do: :ok

  defp resumable_run(%{"status" => status}), do: {:error, {:run_not_resumable, status}}

  defp definition_from_snapshot(run) do
    yaml = run["workflow_yaml"]

    with true <- sha256(yaml) == run["workflow_sha256"] || {:error, :workflow_snapshot_changed},
         {:ok, values} <- YamlElixir.read_from_string(yaml),
         {:ok, definition} <- Definition.new(values) do
      {:ok, definition}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp recovery_action(steps) do
    case Enum.find(steps, &(&1["status"] in ["stopped", "running", "recovery_required"])) do
      nil -> completed_recovery(steps)
      step -> {:ok, {:retry, step["position"]}}
    end
  end

  defp completed_recovery([]), do: {:error, :resumable_step_not_found}

  defp completed_recovery(steps) do
    if Enum.all?(steps, &(&1["status"] == "completed")) do
      {:ok, :finalize}
    else
      {:error, :resumable_step_not_found}
    end
  end

  defp completed_outputs(steps) do
    Enum.reduce_while(steps, {:ok, %{}}, fn step, {:ok, outputs} ->
      if step["status"] == "completed" do
        case Jason.decode(step["result_json"]) do
          {:ok, result} -> {:cont, {:ok, Map.put(outputs, step["name"], result)}}
          {:error, reason} -> {:halt, {:error, {:invalid_step_result, reason}}}
        end
      else
        {:cont, {:ok, outputs}}
      end
    end)
  end

  defp reconcile_options(options), do: Keyword.take(options, [:git])

  defp put_repairs(artifacts, []), do: artifacts
  defp put_repairs(artifacts, repairs), do: Map.put(artifacts, "repairs", repairs)

  defp attach_cleanup(project, result, options) do
    cleanup_api = Keyword.get(options, :failure_cleanup, FailureCleanup)
    %{result | cleanup: cleanup_api.run(project, result, options)}
  end

  defp attach_failure_evidence(project, result, store, options) do
    result = attach_durable_evidence(result, store, options)
    result = attach_cleanup(project, result, options)
    attach_forensics(result, project, options)
  end

  defp attach_durable_evidence(result, store, options) do
    store_api = Keyword.get(options, :store_api, Store)

    operations =
      case store_api.list_steps(store, result.run_id) do
        {:ok, steps} -> Enum.flat_map(steps, &step_operation/1)
        {:error, _reason} -> []
      end

    effects =
      if function_exported?(store_api, :list_effects, 2) do
        case store_api.list_effects(store, result.run_id) do
          {:ok, records} -> Enum.map(records, &effect_evidence/1)
          {:error, _reason} -> []
        end
      else
        []
      end

    if operations == [] and effects == [] do
      result
    else
      evidence = %{"operations" => operations, "effects" => effects}
      %{result | artifacts: Map.put(result.artifacts, "recovery_evidence", evidence)}
    end
  end

  defp step_operation(%{"operation_json" => json} = step) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, operation} when is_map(operation) ->
        [
          operation
          |> Map.put("step", step["name"])
          |> Map.put("step_position", step["position"])
        ]

      _invalid ->
        []
    end
  end

  defp step_operation(_step), do: []

  defp effect_evidence(effect) do
    effect
    |> Map.take([
      "step_position",
      "key",
      "kind",
      "status",
      "attempt",
      "started_at",
      "applied_at"
    ])
    |> Map.put("intent", decode_evidence(effect["intent_json"]))
    |> Map.put("receipt", decode_evidence(effect["receipt_json"]))
    |> Map.put("error", decode_evidence(effect["error_json"]))
  end

  defp decode_evidence(nil), do: nil

  defp decode_evidence(json) do
    case Jason.decode(json) do
      {:ok, value} -> value
      {:error, _reason} -> %{"invalid_json" => true}
    end
  end

  defp attach_forensics(%{status: :stopped} = result, project, options) do
    forensics = Keyword.get(options, :forensics, Forensics)

    case forensics.capture_run(project, result, options) do
      {:ok, path} ->
        %{result | forensic_report: path}

      {:error, reason} ->
        Hancho.Log.internal(:warning, "Failed to write workflow forensic report",
          run_id: result.run_id,
          error: inspect(reason)
        )

        result
    end
  end

  defp attach_forensics(result, _project, _options), do: result

  defp sha256(contents),
    do: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)

  defp log_workflow_source(log, definition, source) do
    Hancho.Audit.write(log, "Workflow snapshot",
      event: "workflow.snapshot",
      metadata: %{
        workflow: definition.name,
        version: definition.version,
        path: source.path,
        yaml: source.yaml,
        sha256: source.sha256
      }
    )
  end

  defp new_run_id do
    suffix = :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
    "#{System.system_time(:millisecond)}-#{suffix}"
  end
end
