defmodule Hancho.Workflow.Repair do
  @moduledoc "Classifies gate failures and prepares bounded coding-agent repairs."

  alias Hancho.Log.Event
  alias Hancho.Workflow.{OnError, RepairRecord, Step}

  @type decision ::
          :stop
          | {:repair, pos_integer(), boolean(), String.t()}
          | {:exhausted, String.t(), non_neg_integer()}

  @spec decision(Step.t(), term(), [map()]) :: decision()
  def decision(%Step{on_error: nil}, _reason, _repairs), do: :stop

  def decision(%Step{on_error: %OnError{} = policy} = step, reason, repairs) do
    with code when is_binary(code) <- error_code(step, reason),
         true <- code in policy.codes do
      step_repairs = Enum.filter(repairs, &(value(&1, "step") == step.name))

      latest = List.last(step_repairs)

      cond do
        is_map(latest) and value(latest, "status") == "running" ->
          {:repair, value(latest, "attempt"), true, code}

        length(step_repairs) < policy.max_attempts ->
          {:repair, length(step_repairs) + 1, false, code}

        true ->
          {:exhausted, code, length(step_repairs)}
      end
    else
      _other -> :stop
    end
  end

  @spec error_code(Step.t(), term()) :: String.t() | nil
  def error_code(step, reason) when is_map(reason) do
    direct_code(reason) ||
      reason |> field(:details) |> direct_code() ||
      error_code_from_message(step, field(reason, :message))
  end

  def error_code(%Step{action: "Hancho.Actions.Verify"}, reason) when is_binary(reason) do
    verification_error_code(reason)
  end

  def error_code(_step, _reason), do: nil

  defp direct_code(reason) when is_map(reason) do
    case field(reason, :code) do
      value when is_atom(value) and not is_nil(value) -> Atom.to_string(value)
      value when is_binary(value) -> value
      _other -> nil
    end
  end

  defp direct_code(_reason), do: nil

  defp error_code_from_message(%Step{action: "Hancho.Actions.Verify"}, message)
       when is_binary(message),
       do: verification_error_code(message)

  defp error_code_from_message(_step, _message), do: nil

  defp verification_error_code(message) do
    if String.starts_with?(message, "Verification failed with exit status"),
      do: "verification_failed"
  end

  defp field(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  @spec prepare(Step.t(), map(), term(), map(), map(), pos_integer()) ::
          {:ok, map(), map()} | {:error, term()}
  def prepare(
        %Step{on_error: %OnError{} = policy} = step,
        resolved_params,
        reason,
        artifacts,
        input,
        attempt
      ) do
    with {:ok, workspace} <- workspace_path(artifacts),
         code when is_binary(code) <- error_code(step, reason) do
      prompt = prompt(step, resolved_params, reason, input, attempt, policy.max_attempts)

      {:ok,
       %{
         prompt: prompt,
         worktree_path: workspace,
         repo_path: input["repo_path"] || input[:repo_path],
         provider: policy.repair_with,
         timeout_ms: policy.timeout_ms,
         idle_timeout_ms: min(policy.idle_timeout_ms, policy.timeout_ms),
         andon_warning_ms: policy.andon_warning_ms,
         productive_warning_ms: policy.andon_warning_ms,
         progress_interval_ms: policy.progress_interval_ms
       }, new_record(step, code, reason, policy.repair_with, prompt, attempt)}
    else
      nil -> {:error, :repair_error_code_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec complete([map()], String.t(), pos_integer(), map()) :: [map()]
  def complete(repairs, step, attempt, result) do
    update(repairs, step, attempt, %{
      "status" => "completed",
      "result" => Event.normalize(result),
      "error" => nil,
      "finished_at" => timestamp()
    })
  end

  @spec fail([map()], String.t(), pos_integer(), term()) :: [map()]
  def fail(repairs, step, attempt, error) do
    update(repairs, step, attempt, %{
      "status" => "failed",
      "error" => Event.normalize(error),
      "finished_at" => timestamp()
    })
  end

  @spec recover_open([map()], String.t()) :: [map()]
  def recover_open(repairs, step) do
    Enum.map(repairs, fn record ->
      if value(record, "step") == step and value(record, "status") == "running" do
        Map.merge(record, %{
          "status" => "recovered",
          "result" => %{"gate_passed" => true},
          "finished_at" => timestamp()
        })
      else
        record
      end
    end)
  end

  @spec exhausted_error(term(), String.t(), non_neg_integer(), pos_integer()) :: map()
  def exhausted_error(reason, code, attempts, maximum) do
    reason
    |> normalized_error(code)
    |> Map.put("repair", %{
      "status" => "exhausted",
      "attempts" => attempts,
      "max_attempts" => maximum
    })
  end

  @spec failed_error(term(), String.t(), pos_integer(), term()) :: map()
  def failed_error(reason, code, attempt, repair_error) do
    %{
      "code" => "repair_failed",
      "cause" => normalized_error(reason, code),
      "repair" => %{
        "status" => "failed",
        "attempt" => attempt,
        "error" => Event.normalize(repair_error)
      }
    }
  end

  @spec from_steps([map()]) :: {:ok, [map()]} | {:error, term()}
  def from_steps(steps) do
    Enum.reduce_while(steps, {:ok, []}, fn step, {:ok, records} ->
      case decode_records(step["repairs_json"]) do
        {:ok, step_records} -> {:cont, {:ok, records ++ step_records}}
        {:error, reason} -> {:halt, {:error, {:invalid_repair_records, step["name"], reason}}}
      end
    end)
  end

  @spec decode_records(String.t() | nil) :: {:ok, [map()]} | {:error, term()}
  def decode_records(nil), do: {:ok, []}

  def decode_records(json) when is_binary(json) do
    with {:ok, values} when is_list(values) <- Jason.decode(json) do
      Enum.reduce_while(values, {:ok, []}, fn value, {:ok, records} ->
        case RepairRecord.new(value) do
          {:ok, record} -> {:cont, {:ok, [RepairRecord.to_map(record) | records]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, records} -> {:ok, Enum.reverse(records)}
        error -> error
      end
    else
      {:ok, _other} -> {:error, :not_an_array}
      {:error, reason} -> {:error, reason}
    end
  end

  defp new_record(step, code, reason, provider, prompt, attempt) do
    {:ok, record} =
      RepairRecord.new(%{
        step: step.name,
        attempt: attempt,
        status: "running",
        code: code,
        provider: provider,
        prompt: prompt,
        prompt_sha256: sha256(prompt),
        trigger_error: Event.normalize(reason),
        result: nil,
        error: nil,
        started_at: timestamp(),
        finished_at: nil
      })

    RepairRecord.to_map(record)
  end

  defp prompt(step, resolved_params, reason, input, attempt, maximum) do
    context = %{
      issue_id: input["issue_id"] || input[:issue_id],
      failed_step: step.name,
      failed_action: step.action,
      attempt: attempt,
      max_attempts: maximum,
      error: Event.normalize(reason),
      gate_params: Event.normalize(resolved_params)
    }

    """
    Repair the failed Hancho workflow gate in the current workspace.

    Keep the implementation focused on the selected Beadwork task. Do not edit the task text, Allowed Scope, or other task metadata. Do not commit changes. Do not change the Git branch or HEAD. Fix only the reported failure, and keep valid source changes.

    After the repair, Hancho will run the failed gate again. If the task requirements conflict with the Allowed Scope, do not broaden the scope. Leave a clear explanation in your final response.

    Failure context:
    ```json
    #{Jason.encode!(context, pretty: true)}
    ```
    """
  end

  defp workspace_path(artifacts) do
    path =
      get_in(artifacts, ["workspace_opened", "workspace_path"]) ||
        get_in(artifacts, ["worktree_created", "worktree_path"])

    cond do
      not is_binary(path) -> {:error, :repair_workspace_not_found}
      not File.dir?(path) -> {:error, {:repair_workspace_not_found, path}}
      true -> {:ok, path}
    end
  end

  defp normalized_error(reason, code) do
    case Event.normalize(reason) do
      value when is_map(value) -> Map.put_new(value, "code", code)
      value -> %{"code" => code, "error" => value}
    end
  end

  defp update(repairs, step, attempt, changes) do
    Enum.map(repairs, fn record ->
      if value(record, "step") == step and value(record, "attempt") == attempt,
        do: Map.merge(record, changes),
        else: record
    end)
  end

  defp value(map, "step"), do: Map.get(map, "step", Map.get(map, :step))
  defp value(map, "status"), do: Map.get(map, "status", Map.get(map, :status))
  defp value(map, "attempt"), do: Map.get(map, "attempt", Map.get(map, :attempt))

  defp sha256(contents),
    do: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)

  defp timestamp do
    DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
  end
end
