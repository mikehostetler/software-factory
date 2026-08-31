defmodule Hancho.MatrixRun.Evidence do
  @moduledoc "Builds comparable evidence from normalized Harness events and Git state."

  @event_output_limit 20_000
  @activity_event_limit 1_000
  @run_scoped_cost_providers [:amp, :claude, :codex, :gemini, :zai]
  @test_command ~r/(^|\s)(mix\s+(test|check)|cargo\s+test|go\s+test|pytest|npm\s+(test|run\s+test)|pnpm\s+test|yarn\s+test|bundle\s+exec\s+rspec)(\s|$)/i
  @test_output ~r/(\d+\s+tests?|\d+\s+passed|0 failures|test result|mix check)/i

  @spec from([term()], map(), String.t() | nil) :: map()
  def from(events, workspace, local_server) do
    events = Enum.map(events, &normalize_event/1)
    tools = Enum.filter(events, &(&1["type"] in ["tool_call", "tool_result"]))

    %{
      "event_count" => length(events),
      "effective_model" => effective_model(events),
      "tool_activity" => activity(tools),
      "file_changes" => file_changes(events, workspace),
      "tests" => tests(tools),
      "local_server" => local_server(events, local_server)
    }
  end

  @spec output(term(), [term()]) :: map()
  def output(result, events) do
    {text, truncated} =
      case result do
        %{text: text, text_truncated?: truncated} when is_binary(text) -> {text, truncated}
        _other -> {event_text(events), false}
      end

    original_size = byte_size(text)
    redacted = redact(text)

    %{
      "text" => tail(redacted, @event_output_limit),
      "truncated" => truncated or original_size > @event_output_limit,
      "sha256" => digest(redacted)
    }
  end

  @spec observed_usage(atom(), term(), [term()]) :: map()
  def observed_usage(provider, result, events) do
    raw =
      case result do
        %{usage: usage} when is_map(usage) and map_size(usage) > 0 -> usage
        _other -> last_payload(events, :usage) || %{}
      end

    provider
    |> Hancho.ProviderUsage.normalize(raw)
    |> Hancho.ProviderUsage.to_map()
  end

  @spec observed_cost(atom(), map(), [term()]) :: map()
  def observed_cost(provider, usage, events) do
    value =
      numeric(usage["values"], ["cost_usd", "total_cost_usd"]) ||
        events
        |> Enum.reverse()
        |> Enum.find_value(fn event ->
          if event_type(event) in [:run_completed, :usage] do
            numeric(event_payload(event), ["cost_usd", "total_cost_usd"])
          end
        end)

    if is_number(value) and value >= 0 do
      scope = cost_scope(provider, usage)

      %{
        "status" => "available",
        "scope" => scope,
        "additive" => scope == "run",
        "value_usd" => value
      }
    else
      %{
        "status" => "unavailable",
        "scope" => "unavailable",
        "additive" => false,
        "value_usd" => nil
      }
    end
  end

  @spec digest(term()) :: String.t()
  def digest(value) do
    :crypto.hash(:sha256, canonical(value))
    |> Base.encode16(case: :lower)
  end

  @spec redact(term()) :: term()
  def redact(value), do: Jido.Harness.Redaction.redact(value)

  defp normalize_event(%Jido.Harness.Event{} = event) do
    %{
      "sequence" => event.sequence,
      "timestamp" => event.timestamp,
      "type" => Atom.to_string(event.type),
      "payload" => event.payload |> redact() |> bounded()
    }
  end

  defp normalize_event(event) when is_map(event) do
    %{
      "sequence" => Map.get(event, :sequence, Map.get(event, "sequence", 0)),
      "timestamp" => Map.get(event, :timestamp, Map.get(event, "timestamp")),
      "type" => event |> event_type() |> to_string(),
      "payload" => event |> event_payload() |> redact() |> bounded()
    }
  end

  defp normalize_event(event) do
    %{
      "sequence" => 0,
      "timestamp" => nil,
      "type" => "unknown",
      "payload" => event |> redact() |> bounded()
    }
  end

  defp bounded(value) when is_binary(value), do: tail(value, @event_output_limit)
  defp bounded(value) when is_list(value), do: Enum.map(value, &bounded/1)

  defp bounded(value) when is_map(value) do
    value
    |> Hancho.Log.Event.normalize()
    |> Map.new(fn {key, item} -> {key, bounded(item)} end)
  end

  defp bounded(value), do: Hancho.Log.Event.normalize(value)

  defp effective_model(events) do
    model =
      Enum.find_value(events, fn event ->
        if event["type"] == "run_started" do
          get_in(event, ["payload", "model"])
        end
      end)

    if is_binary(model) and String.trim(model) != "" do
      %{
        "status" => "observed",
        "value" => String.trim(model),
        "source" => "harness.run_started_payload"
      }
    else
      %{"status" => "unavailable", "value" => nil, "source" => nil}
    end
  end

  defp activity([]) do
    %{
      "status" => "not_observed",
      "event_count" => 0,
      "retained_event_count" => 0,
      "truncated" => false,
      "events" => []
    }
  end

  defp activity(events) do
    retained = Enum.take(events, -@activity_event_limit)

    %{
      "status" => "observed",
      "event_count" => length(events),
      "retained_event_count" => length(retained),
      "truncated" => length(retained) < length(events),
      "events" => retained
    }
  end

  defp file_changes(events, workspace) do
    harness_events =
      events
      |> Enum.filter(&(&1["type"] == "file_change"))
      |> Enum.take(-@activity_event_limit)

    changes = Map.get(workspace, "changes", [])
    status_error = Map.get(workspace, "status_error")
    patch = Map.get(workspace, "patch")

    evidence_error? =
      not is_nil(status_error) or get_in(patch || %{}, ["status"]) == "error" or
        Enum.any?(changes, &(get_in(&1, ["content", "status"]) == "error"))

    %{
      "status" =>
        cond do
          evidence_error? -> "error"
          changes == [] and harness_events == [] -> "not_observed"
          true -> "observed"
        end,
      "workspace" => changes,
      "harness_events" => harness_events,
      "patch" => patch,
      "status_error" => status_error,
      "digest" =>
        digest(%{
          "changes" => changes,
          "status_error" => status_error,
          "patch_status" => get_in(workspace, ["patch", "status"]),
          "patch_sha256" => get_in(workspace, ["patch", "sha256"])
        })
    }
  end

  defp tests(tools) do
    calls =
      tools
      |> Enum.filter(&(&1["type"] == "tool_call"))
      |> Enum.filter(&is_binary(get_in(&1, ["payload", "call_id"])))
      |> Map.new(fn event -> {get_in(event, ["payload", "call_id"]), event} end)

    evidence =
      tools
      |> Enum.filter(&(&1["type"] == "tool_result"))
      |> Enum.filter(fn result ->
        call = Map.get(calls, get_in(result, ["payload", "call_id"]))
        test_event?(call, result)
      end)
      |> Enum.map(fn result ->
        call = Map.get(calls, get_in(result, ["payload", "call_id"]))
        error? = get_in(result, ["payload", "is_error"]) in [true, "true", 1]

        %{
          "sequence" => result["sequence"],
          "name" => call && get_in(call, ["payload", "name"]),
          "input" => call && get_in(call, ["payload", "input"]),
          "status" => if(error?, do: "failed", else: "passed"),
          "output" => get_in(result, ["payload", "output"])
        }
      end)

    %{
      "status" => test_status(evidence),
      "evidence" => evidence
    }
  end

  defp test_event?(nil, result), do: matches?(get_in(result, ["payload", "output"]), @test_output)

  defp test_event?(call, result) do
    matches?(get_in(call, ["payload", "input"]), @test_command) or
      matches?(get_in(result, ["payload", "output"]), @test_output)
  end

  defp test_status([]), do: "not_observed"

  defp test_status(evidence) do
    if Enum.any?(evidence, &(&1["status"] == "failed")), do: "failed", else: "passed"
  end

  defp local_server(_events, nil) do
    %{
      "status" => "not_configured",
      "origin" => nil,
      "source" => "harness_tool_events",
      "server_log_verified" => false,
      "interaction_count" => 0,
      "truncated" => false,
      "interactions" => []
    }
  end

  defp local_server(events, origin) do
    all_interactions =
      events
      |> Enum.filter(fn event ->
        event["type"] in ["tool_call", "tool_result", "command_output_delta"] and
          contains?(event["payload"], origin)
      end)

    interactions = Enum.take(all_interactions, -@activity_event_limit)

    %{
      "status" => if(interactions == [], do: "not_observed", else: "observed"),
      "origin" => origin,
      "source" => "harness_tool_events",
      "server_log_verified" => false,
      "interaction_count" => length(all_interactions),
      "truncated" => length(interactions) < length(all_interactions),
      "interactions" => interactions
    }
  end

  defp contains?(value, text) when is_binary(value), do: String.contains?(value, text)

  defp contains?(value, text) when is_map(value),
    do: Enum.any?(Map.values(value), &contains?(&1, text))

  defp contains?(value, text) when is_list(value), do: Enum.any?(value, &contains?(&1, text))
  defp contains?(_value, _text), do: false

  defp matches?(value, regex) when is_binary(value), do: Regex.match?(regex, value)

  defp matches?(value, regex) when is_map(value) or is_list(value),
    do: matches?(inspect(value), regex)

  defp matches?(_value, _regex), do: false

  defp event_text(events) do
    events
    |> Enum.filter(&(event_type(&1) in [:output_text_delta, :output_text_final]))
    |> Enum.map_join("", &(event_payload(&1)["text"] || ""))
  end

  defp last_payload(events, type) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn event -> if event_type(event) == type, do: event_payload(event) end)
  end

  defp event_type(%{type: type}), do: type

  defp event_type(%{"type" => type}) when is_binary(type) do
    Enum.find(Jido.Harness.Event.types(), :unknown, &(Atom.to_string(&1) == type))
  end

  defp event_type(_event), do: :unknown
  defp event_payload(%{payload: payload}) when is_map(payload), do: payload
  defp event_payload(%{"payload" => payload}) when is_map(payload), do: payload
  defp event_payload(_event), do: %{}

  defp numeric(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      value =
        Enum.find_value(map, fn {map_key, item} -> if to_string(map_key) == key, do: item end)

      if is_number(value), do: value
    end)
  end

  defp numeric(_map, _keys), do: nil

  defp cost_scope(:grok, _usage), do: "provider_cumulative"
  defp cost_scope(_provider, %{"scope" => "run"}), do: "run"
  defp cost_scope(provider, _usage) when provider in @run_scoped_cost_providers, do: "run"
  defp cost_scope(_provider, _usage), do: "provider_reported_unknown"

  defp tail(text, limit) when byte_size(text) <= limit, do: text
  defp tail(text, limit), do: binary_part(text, byte_size(text) - limit, limit)

  defp canonical(value) when is_binary(value), do: value
  defp canonical(value), do: Jason.encode!(Hancho.Log.Event.normalize(value))
end
