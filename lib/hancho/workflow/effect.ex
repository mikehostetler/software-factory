defmodule Hancho.Workflow.Effect do
  @moduledoc "Runs a recoverable external effect with a durable intent and receipt."

  @type reconciliation :: :not_applied | {:ok, map()} | {:error, term()}

  @spec run(map(), String.t(), String.t(), map(), (-> reconciliation()), (-> term())) ::
          {:ok, map()} | {:error, term()}
  def run(context, key, kind, intent, reconcile, apply)
      when is_function(reconcile, 0) and is_function(apply, 0) do
    case Map.get(context, :effect_store) do
      nil -> apply.()
      effect_store -> run_durable(effect_store, key, kind, intent, reconcile, apply)
    end
  end

  defp run_durable(effect_store, key, kind, intent, reconcile, apply) do
    %{api: api, store: store, run_id: run_id, step_position: position} = effect_store

    with {:ok, record} <- api.begin_effect(store, run_id, position, key, kind, intent),
         :ok <- durable(api, store, key) do
      case record["status"] do
        "applied" -> decode_receipt(record)
        "intended" -> reconcile_or_apply(api, store, run_id, position, key, reconcile, apply)
      end
    end
  end

  defp reconcile_or_apply(api, store, run_id, position, key, reconcile, apply) do
    case reconcile.() do
      {:ok, receipt} -> persist_receipt(api, store, run_id, position, key, receipt)
      :not_applied -> apply_and_persist(api, store, run_id, position, key, apply)
      {:error, reason} -> record_error(api, store, run_id, position, key, reason)
    end
  end

  defp apply_and_persist(api, store, run_id, position, key, apply) do
    case apply.() do
      {:ok, receipt} -> persist_receipt(api, store, run_id, position, key, receipt)
      {:error, reason} -> record_error(api, store, run_id, position, key, reason)
    end
  end

  defp persist_receipt(api, store, run_id, position, key, receipt) when is_map(receipt) do
    case api.complete_effect(store, run_id, position, key, receipt) do
      :ok -> {:ok, receipt}
      {:error, reason} -> {:error, {:effect_receipt_failed, reason}}
    end
  end

  defp persist_receipt(_api, _store, _run_id, _position, _key, receipt),
    do: {:error, {:invalid_effect_receipt, receipt}}

  defp record_error(api, store, run_id, position, key, reason) do
    case api.fail_effect(store, run_id, position, key, reason) do
      :ok -> {:error, reason}
      {:error, store_reason} -> {:error, {:effect_failure_record_failed, reason, store_reason}}
    end
  end

  defp decode_receipt(%{"receipt_json" => receipt}) do
    case Jason.decode(receipt) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, decoded} -> {:error, {:invalid_effect_receipt, decoded}}
      {:error, reason} -> {:error, {:invalid_effect_receipt, Exception.message(reason)}}
    end
  end

  defp durable(api, store, key) do
    if function_exported?(api, :flush, 1) do
      case api.flush(store) do
        :ok -> :ok
        {:error, reason} -> {:error, {:effect_intent_flush_failed, key, reason}}
      end
    else
      :ok
    end
  end
end
