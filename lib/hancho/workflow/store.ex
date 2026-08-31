defmodule Hancho.Workflow.Store do
  @moduledoc "Stores durable workflow state in the repository-local Bedrock cluster."

  alias Hancho.Log.Event
  alias Hancho.State.{Bedrock, Repo}

  alias Hancho.Workflow.{
    EffectRecord,
    HandoffRecord,
    AttentionRecord,
    QueueRecord,
    RecordRange,
    Repair,
    RepairRecord,
    RunRecord,
    StepRecord
  }

  @prefix "hancho/workflow/runs/"
  @queue_prefix "hancho/workflow/queues/"
  @active_queue_key "hancho/workflow/queues/active"
  @handoff_prefix "hancho/collaboration/handoffs/"
  @attention_prefix "hancho/collaboration/attention/"

  @spec open(String.t()) :: {:ok, String.t()} | {:error, term()}
  def open(path) do
    case Bedrock.open(path) do
      :ok -> {:ok, Path.expand(path)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Waits until the current state is durable."
  @spec flush(String.t()) :: :ok | {:error, term()}
  def flush(store), do: Bedrock.flush(store)

  @spec create_run(String.t(), String.t(), Hancho.Workflow.Definition.t(), map(), map()) ::
          :ok | {:error, term()}
  def create_run(store, id, definition, input, workflow_source) do
    transact(store, fn ->
      key = run_key(id)

      if Repo.get(key) do
        Repo.rollback(:already_exists)
      else
        put_run(
          key,
          %{
            "record_version" => 1,
            "transition_version" => 0,
            "id" => id,
            "workflow_name" => definition.name,
            "workflow_version" => definition.version,
            "workflow_source_path" => workflow_source.path,
            "workflow_yaml" => workflow_source.yaml,
            "workflow_sha256" => workflow_source.sha256,
            "status" => "running",
            "current_step" => nil,
            "input_json" => encode!(input),
            "started_at" => now(),
            "finished_at" => nil,
            "error_json" => nil
          }
        )
      end
    end)
  end

  @spec start_step(String.t(), String.t(), non_neg_integer(), Hancho.Workflow.Step.t(), map()) ::
          :ok | {:error, term()}
  def start_step(store, run_id, position, step, params) do
    update_run(store, run_id, fn run ->
      if run["status"] != "running" do
        {:error, :run_not_running}
      else
        key = step_key(run_id, position)

        stored_step = %{
          "record_version" => 1,
          "transition_version" => 0,
          "position" => position,
          "name" => step.name,
          "action" => step.action,
          "status" => "running",
          "params_json" => encode!(params),
          "operation_json" => nil,
          "repairs_json" => "[]",
          "result_json" => nil,
          "started_at" => now(),
          "finished_at" => nil,
          "error_json" => nil
        }

        case Repo.get(key) do
          nil ->
            put_step(key, stored_step)
            Map.put(run, "current_step", step.name)

          encoded ->
            case decode_record(encoded, StepRecord) do
              {:ok, %{"status" => "retry_pending"} = existing} ->
                stored_step =
                  stored_step
                  |> Map.put("operation_json", existing["operation_json"])
                  |> Map.put("repairs_json", existing["repairs_json"] || "[]")

                put_step(key, stored_step)
                Map.put(run, "current_step", step.name)

              _other ->
                Repo.rollback({:step_already_exists, position})
            end
        end
      end
    end)
  end

  @spec retry_run(String.t(), String.t(), non_neg_integer()) :: :ok | {:error, term()}
  def retry_run(store, run_id, position) do
    transact(store, fn ->
      run_key = run_key(run_id)
      step_key = step_key(run_id, position)

      with {:ok, run} <- get_run(run_key),
           :ok <- status_in(run, ["stopped", "running", "recovery_required"], :run_not_resumable),
           {:ok, step} <- get_step(step_key),
           :ok <-
             status_in(
               step,
               ["stopped", "running", "recovery_required", "retry_pending"],
               :step_not_resumable
             ) do
        retried_run =
          run
          |> Map.put("status", "running")
          |> Map.put("finished_at", nil)
          |> Map.put("error_json", nil)

        retried_step =
          step
          |> Map.put("status", "retry_pending")
          |> Map.put("finished_at", nil)
          |> Map.put("error_json", nil)

        put_run(run_key, bump(retried_run))
        put_step(step_key, bump(retried_step))
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec resume_run(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def resume_run(store, run_id, step_name) do
    update_run(store, run_id, fn run ->
      with :ok <-
             status_in(
               run,
               ["stopped", "running", "recovery_required"],
               :run_not_resumable
             ) do
        run
        |> Map.put("status", "running")
        |> Map.put("current_step", step_name)
        |> Map.put("finished_at", nil)
        |> Map.put("error_json", nil)
      end
    end)
  end

  @spec complete_step(String.t(), String.t(), non_neg_integer(), map(), map()) ::
          :ok | {:error, term()}
  def complete_step(store, run_id, position, result, _outputs) do
    update_run_and_step(store, run_id, position, fn run, step ->
      with :ok <- status_in(run, ["running"], :run_not_running),
           :ok <- status_in(step, ["running"], :step_not_running) do
        completed_step =
          step
          |> Map.put("status", "completed")
          |> Map.put("result_json", encode!(result))
          |> Map.put("finished_at", now())

        {run, completed_step}
      end
    end)
  end

  @spec complete_run(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def complete_run(store, run_id, _outputs) do
    transact(store, fn ->
      key = run_key(run_id)

      with {:ok, run} <- get_run(key),
           :ok <-
             status_in(
               run,
               ["running", "stopped", "recovery_required"],
               :run_not_completable
             ),
           {:ok, steps} <- read_steps(run_id),
           true <-
             (steps != [] and Enum.all?(steps, &(&1["status"] == "completed"))) ||
               Repo.rollback(:run_has_incomplete_steps) do
        completed =
          run
          |> Map.put("status", "completed")
          |> Map.put("current_step", nil)
          |> Map.put("finished_at", now())
          |> Map.put("error_json", nil)

        put_run(key, bump(completed))
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec fail_step(String.t(), String.t(), non_neg_integer(), term()) :: :ok | {:error, term()}
  def fail_step(store, run_id, position, error) do
    update_run_and_step(store, run_id, position, fn run, step ->
      with :ok <- status_in(step, ["running", "recovery_required"], :step_not_running) do
        stopped_step =
          step
          |> Map.put("status", "stopped")
          |> Map.put("error_json", encode!(error))
          |> Map.put("finished_at", now())

        {run, stopped_step}
      end
    end)
  end

  @spec fail_run(String.t(), String.t(), String.t(), map(), term()) :: :ok | {:error, term()}
  def fail_run(store, run_id, step_name, _outputs, error) do
    update_run(store, run_id, fn run ->
      with :ok <- status_in(run, ["running", "recovery_required"], :run_not_running) do
        run
        |> Map.put("status", "stopped")
        |> Map.put("current_step", step_name)
        |> Map.put("error_json", encode!(error))
        |> Map.put("finished_at", now())
      end
    end)
  end

  @spec stop_run_and_step(String.t(), String.t(), non_neg_integer(), String.t(), term()) ::
          :ok | {:error, term()}
  def stop_run_and_step(store, run_id, position, step_name, error) do
    update_run_and_step(store, run_id, position, fn run, step ->
      with :ok <- status_in(run, ["running", "recovery_required"], :run_not_running),
           :ok <- status_in(step, ["running", "recovery_required"], :step_not_running) do
        stopped_step =
          step
          |> Map.put("status", "stopped")
          |> Map.put("error_json", encode!(error))
          |> Map.put("finished_at", now())

        stopped_run =
          run
          |> Map.put("status", "stopped")
          |> Map.put("current_step", step_name)
          |> Map.put("error_json", encode!(error))
          |> Map.put("finished_at", now())

        {stopped_run, stopped_step}
      end
    end)
  end

  @spec mark_recovery_required(String.t(), String.t(), non_neg_integer(), String.t(), term()) ::
          :ok | {:error, term()}
  def mark_recovery_required(store, run_id, position, step_name, error) do
    update_run_and_step(store, run_id, position, fn run, step ->
      with :ok <-
             status_in(
               run,
               ["running", "stopped", "recovery_required"],
               :run_not_recoverable
             ),
           :ok <-
             status_in(
               step,
               ["running", "stopped", "recovery_required"],
               :step_not_recoverable
             ) do
        required_step =
          step
          |> Map.put("status", "recovery_required")
          |> Map.put("error_json", encode!(error))
          |> Map.put("finished_at", now())

        required_run =
          run
          |> Map.put("status", "recovery_required")
          |> Map.put("current_step", step_name)
          |> Map.put("error_json", encode!(error))
          |> Map.put("finished_at", now())

        {required_run, required_step}
      end
    end)
  end

  @spec mark_run_recovery_required(String.t(), String.t(), String.t() | nil, term()) ::
          :ok | {:error, term()}
  def mark_run_recovery_required(store, run_id, step_name, error) do
    update_run(store, run_id, fn run ->
      with :ok <-
             status_in(
               run,
               ["running", "stopped", "recovery_required"],
               :run_not_recoverable
             ) do
        run
        |> Map.put("status", "recovery_required")
        |> Map.put("current_step", step_name)
        |> Map.put("error_json", encode!(error))
        |> Map.put("finished_at", now())
      end
    end)
  end

  @spec fetch_run(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_run(store, id) do
    transact(store, fn ->
      case Repo.get(run_key(id)) do
        nil ->
          Repo.rollback(:not_found)

        encoded ->
          with {:ok, run} <- decode_record(encoded, RunRecord),
               {:ok, steps} <- read_steps(id) do
            outputs =
              steps
              |> Enum.filter(&(&1["status"] == "completed"))
              |> Map.new(fn step ->
                {step["name"], decode_optional!(step["result_json"])}
              end)

            {:ok, Map.put(run, "outputs_json", encode!(outputs))}
          else
            {:error, reason} -> Repo.rollback(reason)
          end
      end
    end)
  end

  @spec begin_effect(String.t(), String.t(), non_neg_integer(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def begin_effect(store, run_id, position, key, kind, intent) do
    transact(store, fn ->
      effect_key = effect_key(run_id, position, key)
      intent_json = encode!(intent)

      with {:ok, run} <- get_run(run_key(run_id)),
           :ok <- status_in(run, ["running"], :run_not_running),
           {:ok, step} <- get_step(step_key(run_id, position)),
           :ok <- status_in(step, ["running"], :step_not_running) do
        case Repo.get(effect_key) do
          nil ->
            effect = %{
              "record_version" => 1,
              "transition_version" => 0,
              "run_id" => run_id,
              "step_position" => position,
              "key" => key,
              "kind" => kind,
              "status" => "intended",
              "intent_json" => intent_json,
              "receipt_json" => nil,
              "attempt" => 1,
              "started_at" => now(),
              "applied_at" => nil,
              "error_json" => nil
            }

            put_effect(effect_key, effect)
            {:ok, effect}

          encoded ->
            with {:ok, effect} <- decode_record(encoded, EffectRecord),
                 :ok <- same_effect(effect, kind, intent_json) do
              retried =
                effect
                |> Map.update!("attempt", &(&1 + 1))
                |> Map.put("error_json", nil)
                |> bump()

              put_effect(effect_key, retried)
              {:ok, retried}
            else
              {:error, reason} -> Repo.rollback(reason)
            end
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec complete_effect(String.t(), String.t(), non_neg_integer(), String.t(), map()) ::
          :ok | {:error, term()}
  def complete_effect(store, run_id, position, key, receipt) do
    transact(store, fn ->
      effect_key = effect_key(run_id, position, key)
      receipt_json = encode!(receipt)

      with {:ok, effect} <- get_effect(effect_key) do
        case effect do
          %{"status" => "intended"} ->
            applied =
              effect
              |> Map.put("status", "applied")
              |> Map.put("receipt_json", receipt_json)
              |> Map.put("applied_at", now())
              |> Map.put("error_json", nil)

            put_effect(effect_key, bump(applied))

          %{"status" => "applied", "receipt_json" => ^receipt_json} ->
            :ok

          %{"status" => "applied"} ->
            Repo.rollback(:effect_receipt_changed)
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec fail_effect(String.t(), String.t(), non_neg_integer(), String.t(), term()) ::
          :ok | {:error, term()}
  def fail_effect(store, run_id, position, key, error) do
    transact(store, fn ->
      effect_key = effect_key(run_id, position, key)

      with {:ok, effect} <- get_effect(effect_key),
           :ok <- status_in(effect, ["intended"], :effect_already_applied) do
        put_effect(effect_key, effect |> Map.put("error_json", encode!(error)) |> bump())
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec list_steps(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_steps(store, run_id) do
    transact(store, fn ->
      if Repo.get(run_key(run_id)) do
        case read_steps(run_id) do
          {:ok, steps} -> {:ok, steps}
          {:error, reason} -> Repo.rollback(reason)
        end
      else
        Repo.rollback(:not_found)
      end
    end)
  end

  @spec list_effects(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_effects(store, run_id) do
    transact(store, fn ->
      if Repo.get(run_key(run_id)) do
        prefix = effect_prefix(run_id)

        prefix
        |> Elixir.Bedrock.KeyRange.from_prefix()
        |> Repo.get_range()
        |> RecordRange.decode_prefix(prefix, &decode_record(&1, EffectRecord))
        |> case do
          {:ok, effects} -> {:ok, Enum.sort_by(effects, &{&1["step_position"], &1["key"]})}
          {:error, reason} -> Repo.rollback(reason)
        end
      else
        Repo.rollback(:not_found)
      end
    end)
  end

  @spec record_step_operation(
          String.t(),
          String.t(),
          non_neg_integer(),
          String.t(),
          String.t(),
          map()
        ) :: :ok | {:error, term()}
  def record_step_operation(store, run_id, position, kind, id, metadata) do
    update_run_and_step(store, run_id, position, fn run, step ->
      with :ok <- status_in(run, ["running"], :run_not_running),
           :ok <- status_in(step, ["running"], :step_not_running),
           {:ok, previous} <- decode_optional(step["operation_json"]),
           {:ok, operation} <- next_operation(previous, kind, id, metadata) do
        {run, Map.put(step, "operation_json", operation)}
      end
    end)
  end

  @spec fetch_step_operation(String.t(), String.t(), non_neg_integer(), String.t()) ::
          {:ok, map() | nil} | {:error, term()}
  def fetch_step_operation(store, run_id, position, kind) do
    transact(store, fn ->
      with {:ok, step} <- get_step(step_key(run_id, position)) do
        case decode_optional(step["operation_json"]) do
          {:ok, nil} -> {:ok, nil}
          {:ok, %{"kind" => ^kind} = operation} -> {:ok, operation}
          {:ok, %{"kind" => other}} -> Repo.rollback({:operation_kind_changed, other, kind})
          {:ok, other} -> Repo.rollback({:invalid_step_operation, other})
          {:error, reason} -> Repo.rollback(reason)
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec begin_step_repair(String.t(), String.t(), non_neg_integer(), map()) ::
          :ok | {:error, term()}
  def begin_step_repair(store, run_id, position, repair) do
    update_run_and_step(store, run_id, position, fn run, step ->
      with :ok <- status_in(run, ["running"], :run_not_running),
           :ok <- status_in(step, ["running"], :step_not_running),
           {:ok, repairs} <- Repair.decode_records(step["repairs_json"]),
           {:ok, record} <- RepairRecord.new(repair),
           :ok <- same_repair_step(record.step, step["name"]),
           :ok <- repair_status(record.status, "running"),
           :ok <- next_repair_attempt(repairs, record.attempt) do
        updated = repairs ++ [RepairRecord.to_map(record)]
        {run, Map.put(step, "repairs_json", encode!(updated))}
      end
    end)
  end

  @spec complete_step_repair(
          String.t(),
          String.t(),
          non_neg_integer(),
          pos_integer(),
          map()
        ) :: :ok | {:error, term()}
  def complete_step_repair(store, run_id, position, attempt, result) do
    update_repair(store, run_id, position, attempt, fn repairs, step_name ->
      Repair.complete(repairs, step_name, attempt, result)
    end)
  end

  @spec fail_step_repair(String.t(), String.t(), non_neg_integer(), pos_integer(), term()) ::
          :ok | {:error, term()}
  def fail_step_repair(store, run_id, position, attempt, error) do
    update_repair(store, run_id, position, attempt, fn repairs, step_name ->
      Repair.fail(repairs, step_name, attempt, error)
    end)
  end

  @spec recover_step_repairs(String.t(), String.t(), non_neg_integer()) ::
          :ok | {:error, term()}
  def recover_step_repairs(store, run_id, position) do
    update_run_and_step(store, run_id, position, fn run, step ->
      with :ok <- status_in(run, ["running"], :run_not_running),
           :ok <- status_in(step, ["running"], :step_not_running),
           {:ok, repairs} <- Repair.decode_records(step["repairs_json"]) do
        recovered = Repair.recover_open(repairs, step["name"])
        {run, Map.put(step, "repairs_json", encode!(recovered))}
      end
    end)
  end

  @spec create_queue(String.t(), String.t(), String.t(), String.t(), [map()], map()) ::
          :ok | {:error, term()}
  def create_queue(store, id, workflow, source, items, repository_state) do
    transact(store, fn ->
      if active = Repo.get(@active_queue_key) do
        Repo.rollback({:queue_already_running, active})
      else
        queue = %{
          "record_version" => 2,
          "transition_version" => 0,
          "id" => id,
          "workflow_name" => workflow,
          "source" => source,
          "status" => "running",
          "repository" => repository_state.repository,
          "expected_branch" => repository_state.branch,
          "expected_head" => repository_state.head,
          "expected_worktrees" => Map.get(repository_state, :expected_worktrees, []),
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
          "started_at" => now(),
          "finished_at" => nil,
          "error" => nil
        }

        put_queue(queue_key(id), queue)
        Repo.put(@active_queue_key, id)
      end
    end)
  end

  @spec start_queue_item(String.t(), String.t(), non_neg_integer()) ::
          :ok | {:error, term()}
  def start_queue_item(store, queue_id, position) do
    update_queue(store, queue_id, fn queue ->
      with :ok <- queue_position(queue, position),
           {:ok, item} <- queue_item(queue, position),
           :ok <- item_status(item, "pending") do
        queue
        |> put_queue_item(position, Map.put(item, "status", "running"))
        |> Map.put("current_run_id", item["run_id"])
      end
    end)
  end

  @spec complete_queue_item(String.t(), String.t(), non_neg_integer(), String.t()) ::
          :ok | {:error, term()}
  def complete_queue_item(store, queue_id, position, expected_head) do
    update_queue(store, queue_id, fn queue ->
      with :ok <- queue_position(queue, position),
           {:ok, item} <- queue_item(queue, position),
           :ok <- item_status(item, "running") do
        queue
        |> put_queue_item(
          position,
          item
          |> Map.put("status", "completed")
          |> Map.put("error", nil)
        )
        |> Map.put("expected_head", expected_head)
        |> Map.put("current_position", position + 1)
        |> Map.put("current_run_id", nil)
      end
    end)
  end

  @spec stop_queue_item(String.t(), String.t(), non_neg_integer(), term()) ::
          :ok | {:error, term()}
  def stop_queue_item(store, queue_id, position, error) do
    transact(store, fn ->
      with {:ok, queue} <- get_queue(queue_key(queue_id)),
           :ok <- queue_position(queue, position),
           {:ok, item} <- queue_item(queue, position),
           :ok <- status_in(item, ["pending", "running"], :queue_item_not_stoppable) do
        stopped_item =
          item
          |> Map.put("status", "stopped")
          |> Map.put("error", Event.normalize(error))

        queue =
          queue
          |> put_queue_item(position, stopped_item)
          |> stop_queue(error)

        put_queue(queue_key(queue_id), bump(queue))
        Repo.clear(@active_queue_key)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec resume_queue(String.t(), String.t()) :: :ok | {:error, term()}
  def resume_queue(store, queue_id) do
    transact(store, fn ->
      active = Repo.get(@active_queue_key)

      with :ok <- active_queue_available(active, queue_id),
           {:ok, queue} <- get_queue(queue_key(queue_id)),
           :ok <-
             status_in(queue, ["stopped", "running", "recovery_required"], :queue_not_resumable),
           position = queue["current_position"] do
        if position == length(queue["items"]) and
             Enum.all?(queue["items"], &(&1["status"] == "completed")) do
          resumed_queue =
            queue
            |> Map.put("status", "running")
            |> Map.put("current_run_id", nil)
            |> Map.put("finished_at", nil)
            |> Map.put("error", nil)

          put_queue(queue_key(queue_id), bump(resumed_queue))
          Repo.put(@active_queue_key, queue_id)
        else
          with {:ok, item} <- queue_item(queue, position),
               :ok <-
                 status_in(
                   item,
                   ["pending", "stopped", "running"],
                   :queue_item_not_resumable
                 ) do
            resumed_item =
              item
              |> Map.put("status", "running")
              |> Map.put("error", nil)

            resumed_queue =
              queue
              |> put_queue_item(position, resumed_item)
              |> Map.put("status", "running")
              |> Map.put("current_run_id", item["run_id"])
              |> Map.put("finished_at", nil)
              |> Map.put("error", nil)

            put_queue(queue_key(queue_id), bump(resumed_queue))
            Repo.put(@active_queue_key, queue_id)
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec fail_queue(String.t(), String.t(), term()) :: :ok | {:error, term()}
  def fail_queue(store, queue_id, error) do
    transact(store, fn ->
      with {:ok, queue} <- get_queue(queue_key(queue_id)),
           :ok <- status_in(queue, ["running", "recovery_required"], :queue_not_running) do
        put_queue(queue_key(queue_id), queue |> stop_queue(error) |> bump())
        Repo.clear(@active_queue_key)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec complete_queue(String.t(), String.t()) :: :ok | {:error, term()}
  def complete_queue(store, queue_id) do
    transact(store, fn ->
      with {:ok, queue} <- get_queue(queue_key(queue_id)),
           :ok <- status_in(queue, ["running"], :queue_not_running),
           true <-
             Enum.all?(queue["items"], &(&1["status"] == "completed")) ||
               Repo.rollback(:queue_has_incomplete_items) do
        completed =
          queue
          |> Map.put("status", "completed")
          |> Map.put("current_run_id", nil)
          |> Map.put("finished_at", now())

        put_queue(queue_key(queue_id), bump(completed))
        Repo.clear(@active_queue_key)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec fetch_queue(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_queue(store, id) do
    transact(store, fn ->
      case get_queue(queue_key(id)) do
        {:ok, queue} -> {:ok, queue}
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec create_handoff(String.t(), String.t(), map(), keyword()) :: :ok | {:error, term()}
  def create_handoff(store, run_id, attributes, _options \\ []) do
    id = run_id <> ":" <> to_string(attributes.from_step) <> ":" <> to_string(attributes.to_step)

    transact(store, fn ->
      key = @handoff_prefix <> encoded_id(id)

      if Repo.get(key) do
        :ok
      else
        put_record(
          key,
          %{
            "record_version" => 1,
            "transition_version" => 0,
            "id" => id,
            "run_id" => run_id,
            "from_role" => to_string(attributes.from_role),
            "to_role" => to_string(attributes.to_role),
            "from_step" => to_string(attributes.from_step),
            "to_step" => to_string(attributes.to_step),
            "artifact" => attributes.artifact,
            "payload_json" => encode!(attributes.payload),
            "status" => "ready",
            "created_at" => now(),
            "accepted_at" => nil,
            "completed_at" => nil
          },
          HandoffRecord
        )
      end
    end)
  end

  @spec list_handoffs(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_handoffs(store), do: list_records(store, @handoff_prefix, HandoffRecord)

  @spec accept_handoff(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def accept_handoff(store, run_id, to_step) do
    update_handoff(store, run_id, to_step, fn
      %{"status" => "ready"} = record ->
        record |> Map.put("status", "accepted") |> Map.put("accepted_at", now())

      %{"status" => status} when status in ["accepted", "completed"] ->
        :unchanged

      _record ->
        {:error, :handoff_not_acceptable}
    end)
  end

  @spec complete_handoff(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def complete_handoff(store, run_id, to_step) do
    update_handoff(store, run_id, to_step, fn
      %{"status" => "accepted"} = record ->
        record |> Map.put("status", "completed") |> Map.put("completed_at", now())

      %{"status" => "completed"} ->
        :unchanged

      _record ->
        {:error, :handoff_not_completable}
    end)
  end

  @spec request_attention(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def request_attention(store, attributes) do
    id = attributes.id

    transact(store, fn ->
      key = @attention_prefix <> encoded_id(id)

      case Repo.get(key) do
        nil ->
          record = %{
            "record_version" => 1,
            "transition_version" => 0,
            "id" => id,
            "run_id" => attributes.run_id,
            "step" => attributes.step,
            "role" => Map.get(attributes, :role),
            "kind" => attributes.kind,
            "title" => attributes.title,
            "body" => attributes.body,
            "status" => "pending",
            "response" => nil,
            "created_at" => now(),
            "resolved_at" => nil
          }

          put_record(key, record, AttentionRecord)
          {:ok, record}

        encoded ->
          decode_record(encoded, AttentionRecord)
      end
    end)
  end

  @spec resolve_attention(String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def resolve_attention(store, id, status, response \\ nil)
      when status in ["approved", "rejected", "answered"] do
    transact(store, fn ->
      key = @attention_prefix <> encoded_id(id)

      with {:ok, record} <- get_record(key, AttentionRecord),
           true <- record["status"] == "pending" || Repo.rollback(:attention_already_resolved) do
        updated =
          record
          |> Map.put("status", status)
          |> Map.put("response", response)
          |> Map.put("resolved_at", now())
          |> bump()

        put_record(key, updated, AttentionRecord)
        {:ok, updated}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec fetch_attention(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_attention(store, id) do
    transact(store, fn ->
      case get_record(@attention_prefix <> encoded_id(id), AttentionRecord) do
        {:ok, record} -> {:ok, record}
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec list_attention(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_attention(store), do: list_records(store, @attention_prefix, AttentionRecord)

  @spec list_runs(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_runs(store) do
    transact(store, fn ->
      @prefix
      |> Elixir.Bedrock.KeyRange.from_prefix()
      |> Repo.get_range()
      |> Enum.reduce_while({:ok, []}, fn {key, value}, {:ok, records} ->
        if String.ends_with?(key, "/run") do
          case decode_record(value, RunRecord) do
            {:ok, record} -> {:cont, {:ok, [record | records]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        else
          {:cont, {:ok, records}}
        end
      end)
      |> case do
        {:ok, records} -> {:ok, Enum.reverse(records)}
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec list_queues(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_queues(store) do
    transact(store, fn ->
      @queue_prefix
      |> Elixir.Bedrock.KeyRange.from_prefix()
      |> Repo.get_range()
      |> Enum.reduce_while({:ok, []}, fn {key, value}, {:ok, records} ->
        if String.ends_with?(key, "/queue") do
          case decode_record(value, QueueRecord) do
            {:ok, record} -> {:cont, {:ok, [record | records]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        else
          {:cont, {:ok, records}}
        end
      end)
      |> case do
        {:ok, records} -> {:ok, Enum.reverse(records)}
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp list_records(store, prefix, module) do
    transact(store, fn ->
      case read_records(prefix, module) do
        {:ok, records} -> {:ok, records}
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp update_handoff(store, run_id, to_step, transition) do
    transact(store, fn ->
      with {:ok, handoffs} <- read_records(@handoff_prefix, HandoffRecord),
           record when is_map(record) <-
             Enum.find(handoffs, &(&1["run_id"] == run_id and &1["to_step"] == to_step)) ||
               Repo.rollback(:handoff_not_found) do
        case transition.(record) do
          :unchanged ->
            :ok

          {:error, reason} ->
            Repo.rollback(reason)

          updated ->
            put_record(
              @handoff_prefix <> encoded_id(record["id"]),
              bump(updated),
              HandoffRecord
            )
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp read_records(prefix, module) do
    prefix
    |> Elixir.Bedrock.KeyRange.from_prefix()
    |> Repo.get_range()
    |> RecordRange.decode_prefix(prefix, &decode_record(&1, module))
  end

  defp update_repair(store, run_id, position, attempt, function) do
    update_run_and_step(store, run_id, position, fn run, step ->
      with :ok <- status_in(run, ["running"], :run_not_running),
           :ok <- status_in(step, ["running"], :step_not_running),
           {:ok, repairs} <- Repair.decode_records(step["repairs_json"]),
           {:ok, record} <- repair_attempt(repairs, attempt),
           :ok <- status_in(record, ["running"], :repair_not_running),
           updated <- function.(repairs, step["name"]),
           :ok <- validate_repair_records(updated) do
        {run, Map.put(step, "repairs_json", encode!(updated))}
      end
    end)
  end

  defp next_operation(nil, kind, id, metadata) do
    {:ok, encode!(%{kind: kind, id: id, metadata: metadata, history: []})}
  end

  defp next_operation(%{"kind" => kind, "id" => id} = current, kind, id, metadata) do
    history = Map.get(current, "history", [])
    {:ok, encode!(%{kind: kind, id: id, metadata: metadata, history: history})}
  end

  defp next_operation(%{"kind" => kind} = current, kind, id, metadata) do
    history = Map.get(current, "history", [])
    prior = Map.drop(current, ["history"])

    {:ok,
     encode!(%{
       kind: kind,
       id: id,
       metadata: metadata,
       history: Enum.take(history ++ [prior], -20)
     })}
  end

  defp next_operation(%{"kind" => other}, kind, _id, _metadata),
    do: {:error, {:operation_kind_changed, other, kind}}

  defp next_operation(other, _kind, _id, _metadata),
    do: {:error, {:invalid_step_operation, other}}

  defp next_repair_attempt(repairs, attempt) do
    if attempt == length(repairs) + 1,
      do: :ok,
      else: {:error, {:invalid_repair_attempt, attempt}}
  end

  defp same_repair_step(step, step), do: :ok
  defp same_repair_step(_actual, _expected), do: {:error, :repair_step_changed}

  defp repair_status(status, status), do: :ok
  defp repair_status(_actual, _expected), do: {:error, :invalid_repair_status}

  defp repair_attempt(repairs, attempt) do
    case Enum.find(repairs, &(&1["attempt"] == attempt)) do
      nil -> {:error, {:repair_attempt_not_found, attempt}}
      record -> {:ok, record}
    end
  end

  defp validate_repair_records(records) do
    Enum.reduce_while(records, :ok, fn record, :ok ->
      case RepairRecord.new(record) do
        {:ok, _record} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:invalid_repair_record, reason}}}
      end
    end)
  end

  defp update_run(store, run_id, function) do
    transact(store, fn ->
      key = run_key(run_id)

      with {:ok, run} <- get_run(key) do
        case function.(run) do
          %{} = updated -> put_run(key, bump(updated))
          {:error, reason} -> Repo.rollback(reason)
          other -> Repo.rollback({:invalid_run_transition, other})
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp update_queue(store, queue_id, function) do
    transact(store, fn ->
      key = queue_key(queue_id)

      with {:ok, queue} <- get_queue(key) do
        case function.(queue) do
          %{} = updated -> put_queue(key, bump(updated))
          {:error, reason} -> Repo.rollback(reason)
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp update_run_and_step(store, run_id, position, function) do
    transact(store, fn ->
      run_key = run_key(run_id)
      step_key = step_key(run_id, position)

      with {:ok, run} <- get_run(run_key),
           {:ok, step} <- get_step(step_key) do
        case function.(run, step) do
          {:error, reason} ->
            Repo.rollback(reason)

          {updated_run, updated_step} ->
            put_run(run_key, bump(updated_run))
            put_step(step_key, bump(updated_step))
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp get_run(key), do: get_record(key, RunRecord)
  defp get_step(key), do: get_record(key, StepRecord)
  defp get_queue(key), do: get_record(key, QueueRecord)
  defp get_effect(key), do: get_record(key, EffectRecord)

  defp get_record(key, module) do
    case Repo.get(key) do
      nil -> {:error, :not_found}
      encoded -> decode_record(encoded, module)
    end
  end

  defp read_steps(run_id) do
    prefix = step_prefix(run_id)

    prefix
    |> Elixir.Bedrock.KeyRange.from_prefix()
    |> Repo.get_range()
    |> RecordRange.decode_prefix(prefix, &decode_record(&1, StepRecord))
    |> case do
      {:ok, steps} -> {:ok, Enum.sort_by(steps, & &1["position"])}
      error -> error
    end
  end

  defp run_key(run_id), do: @prefix <> encoded_id(run_id) <> "/run"
  defp queue_key(queue_id), do: @queue_prefix <> encoded_id(queue_id) <> "/queue"
  defp step_prefix(run_id), do: @prefix <> encoded_id(run_id) <> "/steps/"
  defp effect_prefix(run_id), do: @prefix <> encoded_id(run_id) <> "/effects/"

  defp step_key(run_id, position) do
    step_prefix(run_id) <> String.pad_leading(Integer.to_string(position), 12, "0")
  end

  defp effect_key(run_id, position, key) do
    effect_prefix(run_id) <>
      String.pad_leading(Integer.to_string(position), 12, "0") <>
      "/" <> encoded_id(key)
  end

  defp encoded_id(run_id), do: Base.url_encode64(run_id, padding: false)

  defp queue_position(%{"status" => "running", "current_position" => position}, position),
    do: :ok

  defp queue_position(_queue, _position), do: {:error, :invalid_queue_position}

  defp queue_item(queue, position) do
    case Enum.at(queue["items"], position) do
      nil -> {:error, :queue_item_not_found}
      item -> {:ok, item}
    end
  end

  defp item_status(%{"status" => status}, status), do: :ok
  defp item_status(_item, _status), do: {:error, :invalid_queue_item_status}

  defp status_in(%{"status" => status}, allowed, error) do
    if status in allowed, do: :ok, else: {:error, error}
  end

  defp status_in(_record, _allowed, error), do: {:error, error}

  defp active_queue_available(nil, _queue_id), do: :ok
  defp active_queue_available(queue_id, queue_id), do: :ok
  defp active_queue_available(active, _queue_id), do: {:error, {:queue_already_running, active}}

  defp same_effect(%{"kind" => kind, "intent_json" => intent_json}, kind, intent_json), do: :ok
  defp same_effect(_effect, _kind, _intent_json), do: {:error, :effect_intent_changed}

  defp put_queue_item(queue, position, item) do
    Map.update!(queue, "items", &List.replace_at(&1, position, item))
  end

  defp stop_queue(queue, error) do
    queue
    |> Map.put("status", "stopped")
    |> Map.put("error", Event.normalize(error))
    |> Map.put("finished_at", now())
  end

  defp transact(store, function), do: Bedrock.transaction(store, function)

  defp put_run(key, value), do: put_record(key, value, RunRecord)
  defp put_step(key, value), do: put_record(key, value, StepRecord)
  defp put_queue(key, value), do: put_record(key, value, QueueRecord)
  defp put_effect(key, value), do: put_record(key, value, EffectRecord)

  defp put_record(key, value, module) do
    case module.new(value) do
      {:ok, record} -> Repo.put(key, record |> module.to_map() |> encode!())
      {:error, reason} -> Repo.rollback({:invalid_state_record, module, reason})
    end
  end

  defp decode_record(value, module) do
    with {:ok, decoded} <- decode(value),
         upgraded <- upgrade_record(module, decoded),
         {:ok, record} <- module.new(upgraded) do
      {:ok, module.to_map(record)}
    else
      {:error, reason} -> {:error, {:invalid_state_record, module, reason}}
    end
  end

  defp upgrade_record(module, decoded) do
    if function_exported?(module, :upgrade, 1), do: module.upgrade(decoded), else: decoded
  end

  defp bump(record),
    do: Map.update(record, "transition_version", 1, &(&1 + 1))

  defp encode!(value), do: value |> Event.normalize() |> Jason.encode!()

  defp decode(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:invalid_state, Exception.message(reason)}}
    end
  end

  defp decode_optional!(nil), do: nil
  defp decode_optional!(value), do: Jason.decode!(value)

  defp decode_optional(nil), do: {:ok, nil}

  defp decode_optional(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:invalid_state, Exception.message(reason)}}
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
