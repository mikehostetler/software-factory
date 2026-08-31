defmodule Hancho.MatrixRun.Comparison do
  @moduledoc "Compares matrix evidence without selecting a preferred result."

  @spec build([map()], String.t() | nil) :: map()
  def build(runs, local_server) do
    reasons = incomplete_reasons(runs, local_server)
    differences = differences(runs)
    complete? = reasons == []

    %{
      "status" => if(complete?, do: "complete", else: "incomplete"),
      "ranking" => "not_performed",
      "winner" => nil,
      "notice" => notice(complete?),
      "incomplete_reasons" => reasons,
      "differences" => differences,
      "same_output" => same?(runs, &get_in(&1, ["output", "sha256"])),
      "same_file_changes" => same?(runs, &get_in(&1, ["evidence", "file_changes", "digest"])),
      "usage" => usage_summary(runs),
      "cost" => cost_summary(runs)
    }
  end

  defp incomplete_reasons(runs, local_server) do
    []
    |> add_reason(
      Enum.any?(runs, &(&1["status"] != "completed")),
      "One or more matrix cells did not complete."
    )
    |> add_reason(
      Enum.any?(runs, &(get_in(&1, ["evidence", "effective_model", "status"]) != "observed")),
      "One or more effective models were not observable."
    )
    |> add_reason(
      Enum.any?(runs, &(get_in(&1, ["usage", "status"]) != "available")),
      "One or more providers did not report usage."
    )
    |> add_reason(
      Enum.any?(runs, &(get_in(&1, ["usage", "additive"]) != true)),
      "One or more usage reports were not safe to add."
    )
    |> add_reason(
      Enum.any?(runs, &(get_in(&1, ["cost", "status"]) != "available")),
      "One or more providers did not report cost."
    )
    |> add_reason(
      Enum.any?(runs, &(get_in(&1, ["evidence", "tests", "status"]) == "not_observed")),
      "One or more cells have no observed test result."
    )
    |> add_reason(
      Enum.any?(runs, &(get_in(&1, ["evidence", "file_changes", "status"]) == "error")),
      "One or more cells have incomplete Git file evidence."
    )
    |> add_reason(
      Enum.any?(runs, &get_in(&1, ["output", "truncated"])),
      "One or more output values were truncated."
    )
    |> add_reason(
      is_binary(local_server) and
        Enum.any?(runs, &(get_in(&1, ["evidence", "local_server", "status"]) != "observed")),
      "One or more cells have no observed local-server interaction."
    )
  end

  defp add_reason(reasons, true, reason), do: reasons ++ [reason]
  defp add_reason(reasons, false, _reason), do: reasons

  defp notice(true), do: "These differences are observations. Hancho does not rank the cells."

  defp notice(false) do
    "These differences are observations. Hancho does not select a winner from incomplete evidence."
  end

  defp differences(runs) do
    [
      difference("status", runs, & &1["status"]),
      difference("requested_model", runs, & &1["requested_model"]),
      difference(
        "requested_model_matches_effective",
        runs,
        & &1["requested_model_matches_effective"]
      ),
      grouped_difference("output", runs, &get_in(&1, ["output", "sha256"])),
      grouped_difference(
        "file_changes",
        runs,
        &get_in(&1, ["evidence", "file_changes", "digest"])
      ),
      difference("tests", runs, &get_in(&1, ["evidence", "tests", "status"])),
      difference(
        "effective_model",
        runs,
        &get_in(&1, ["evidence", "effective_model", "value"])
      ),
      difference("elapsed_ms", runs, &get_in(&1, ["timing", "elapsed_ms"])),
      difference("total_tokens", runs, &get_in(&1, ["usage", "values", "total_tokens"])),
      difference("cost_usd", runs, &get_in(&1, ["cost", "value_usd"]))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp difference(field, runs, accessor) do
    values = Map.new(runs, &{&1["cell_id"], accessor.(&1)})

    if values |> Map.values() |> Enum.uniq() |> length() > 1 do
      %{"field" => field, "values" => values}
    end
  end

  defp grouped_difference(field, runs, accessor) do
    groups =
      runs
      |> Enum.group_by(accessor, & &1["cell_id"])
      |> Map.new(fn {value, cell_ids} -> {value || "unavailable", cell_ids} end)

    if map_size(groups) > 1 do
      %{"field" => field, "groups" => groups}
    end
  end

  defp same?([], _accessor), do: nil
  defp same?(runs, accessor), do: runs |> Enum.map(accessor) |> Enum.uniq() |> length() == 1

  defp usage_summary(runs) do
    runs
    |> Enum.map(& &1["usage"])
    |> Enum.reject(&is_nil/1)
    |> Hancho.ProviderUsage.summarize()
  end

  defp cost_summary(runs) do
    costs = Enum.map(runs, & &1["cost"])
    additive = Enum.filter(costs, &(&1 && &1["additive"] == true))
    available = Enum.filter(costs, &(&1 && &1["status"] == "available"))

    %{
      "status" => summary_status(costs, available, additive),
      "value_usd" => Enum.reduce(additive, 0.0, &(&2 + &1["value_usd"])),
      "additive_task_count" => length(additive),
      "excluded_task_count" => length(available) - length(additive),
      "unavailable_task_count" => length(costs) - length(available)
    }
  end

  defp summary_status(_costs, [], _additive), do: "unavailable"

  defp summary_status(costs, available, _additive) when length(costs) > length(available),
    do: "partial"

  defp summary_status(_costs, available, []) when available != [], do: "non_additive"

  defp summary_status(_costs, available, additive) when length(available) > length(additive),
    do: "partial"

  defp summary_status(_costs, _available, _additive), do: "available"
end
