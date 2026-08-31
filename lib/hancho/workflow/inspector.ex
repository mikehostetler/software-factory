defmodule Hancho.Workflow.Inspector do
  @moduledoc "Builds one read-only report from durable workflow state."

  alias Hancho.Workflow.{Artifacts, Store}

  @spec inspect(Hancho.Project.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def inspect(project, run_id, options \\ []) do
    store_api = Keyword.get(options, :store_api, Store)

    with {:ok, store} <- store_api.open(project.bedrock_path) do
      inspect_with_store(project, store_api, store, run_id)
    end
  end

  defp inspect_with_store(project, store_api, store, run_id) do
    with {:ok, run} <- store_api.fetch_run(store, run_id),
         {:ok, steps} <- store_api.list_steps(store, run_id),
         {:ok, effects} <- effects(store_api, store, run_id),
         {:ok, outputs} <- Jason.decode(run["outputs_json"]) do
      artifacts = Artifacts.from_steps(steps, outputs)

      {:ok,
       %{
         run_id: run["id"],
         workflow: run["workflow_name"],
         status: run["status"],
         current_step: run["current_step"],
         started_at: run["started_at"],
         finished_at: run["finished_at"],
         duration_ms: duration(run["started_at"], run["finished_at"]),
         provider: provider_result(artifacts, steps),
         verification: verification_result(artifacts),
         commit:
           get_in(artifacts, ["landing", "commit"]) || get_in(artifacts, ["commit", "commit"]),
         retained_worktree: retained_worktree(artifacts),
         forensic_report: forensic_report(project, run_id),
         failure: decode_optional(run["error_json"]),
         effects: Enum.map(effects, &effect_report/1),
         steps: Enum.map(steps, &step_report/1)
       }}
    end
  end

  defp provider_result(artifacts, steps) do
    case artifacts["implementation"] do
      nil ->
        provider_operation(steps)

      result ->
        Map.take(result, [
          "provider",
          "model",
          "model_source",
          "harness_run_id",
          "status",
          "provider_elapsed_ms",
          "provider_elapsed_scope",
          "usage",
          "credential_protection",
          "text",
          "text_truncated"
        ])
    end
  end

  defp provider_operation(steps) do
    steps
    |> Enum.map(&decode_optional(&1["operation_json"]))
    |> Enum.find(fn
      %{"kind" => kind} -> kind in ["jido_harness.run", "jido_harness.repair"]
      _other -> false
    end)
    |> case do
      %{"id" => id, "metadata" => metadata} = operation ->
        %{
          "harness_run_id" => id,
          "provider" => metadata["provider"],
          "model" => metadata["configured_model"],
          "model_source" => metadata["model_source"],
          "status" => metadata["terminal_status"],
          "last_event" => metadata["last_event"],
          "last_sequence" => metadata["last_sequence"],
          "error" => metadata["error"],
          "history" => Map.get(operation, "history", [])
        }
        |> Map.reject(fn {_key, value} -> is_nil(value) end)

      _other ->
        nil
    end
  end

  defp verification_result(artifacts) do
    case artifacts["verification"] do
      nil ->
        nil

      result ->
        %{
          exit_status: result["exit_status"],
          summary: verification_summary(result["output"] || ""),
          output_path: result["output_path"]
        }
    end
  end

  defp verification_summary(output) do
    case Regex.scan(~r/^Result:\s*.+$/m, output) |> List.last() do
      [summary] -> summary
      nil -> output |> String.split("\n", trim: true) |> List.last()
    end
  end

  defp retained_worktree(artifacts) do
    case {artifacts["worktree_created"], artifacts["worktree_removed"]} do
      {%{"worktree_path" => path}, nil} -> path
      _other -> nil
    end
  end

  defp forensic_report(project, run_id) do
    path = Hancho.Forensics.run_report_path(project, run_id)
    if File.regular?(path), do: path
  end

  defp step_report(step) do
    %{
      position: step["position"],
      name: step["name"],
      action: step["action"],
      status: step["status"],
      started_at: step["started_at"],
      finished_at: step["finished_at"],
      duration_ms: duration(step["started_at"], step["finished_at"]),
      operation: decode_optional(step["operation_json"]),
      repairs: repair_records(step["repairs_json"]),
      error: decode_optional(step["error_json"])
    }
  end

  defp effects(store_api, store, run_id) do
    if function_exported?(store_api, :list_effects, 2),
      do: store_api.list_effects(store, run_id),
      else: {:ok, []}
  end

  defp effect_report(effect) do
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
    |> Map.put("intent", decode_optional(effect["intent_json"]))
    |> Map.put("receipt", decode_optional(effect["receipt_json"]))
    |> Map.put("error", decode_optional(effect["error_json"]))
  end

  defp repair_records(json) do
    case Hancho.Workflow.Repair.decode_records(json) do
      {:ok, records} -> records
      {:error, reason} -> [%{"status" => "invalid", "error" => inspect(reason)}]
    end
  end

  defp duration(nil, _finished_at), do: nil

  defp duration(started_at, finished_at) do
    with {:ok, started, _offset} <- DateTime.from_iso8601(started_at),
         {:ok, finished, _offset} <-
           DateTime.from_iso8601(finished_at || DateTime.to_iso8601(DateTime.utc_now())) do
      DateTime.diff(finished, started, :millisecond)
    else
      _error -> nil
    end
  end

  defp decode_optional(nil), do: nil

  defp decode_optional(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> value
    end
  end
end
