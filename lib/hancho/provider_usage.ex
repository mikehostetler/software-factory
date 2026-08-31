defmodule Hancho.ProviderUsage do
  @moduledoc "Labels normalized provider usage with safe aggregation semantics."

  @run_scoped [:amp, :claude, :codex, :gemini, :zai]

  @schema Zoi.struct(
            __MODULE__,
            %{
              status: Zoi.enum(["available", "unavailable"]),
              scope:
                Zoi.enum([
                  "run",
                  "provider_cumulative",
                  "provider_reported_unknown",
                  "unavailable"
                ]),
              additive: Zoi.boolean(),
              values: Zoi.map()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec normalize(atom(), map()) :: t()
  def normalize(_provider, usage) when usage == %{} do
    new!("unavailable", "unavailable", false, %{})
  end

  def normalize(provider, usage) when is_map(usage) do
    values =
      usage
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.filter(fn {_key, value} -> is_number(value) and value >= 0 end)
      |> put_total_tokens()

    cond do
      values == %{} -> new!("unavailable", "unavailable", false, %{})
      provider == :grok -> new!("available", "provider_cumulative", false, values)
      provider in @run_scoped -> new!("available", "run", true, values)
      true -> new!("available", "provider_reported_unknown", false, values)
    end
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = usage) do
    usage
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  @spec summarize([map()]) :: map()
  def summarize(usages) do
    available = Enum.filter(usages, &(value(&1, "status") == "available"))
    additive = Enum.filter(available, &value(&1, "additive"))
    excluded = length(available) - length(additive)

    totals =
      Enum.reduce(additive, %{}, fn usage, totals ->
        Enum.reduce(value(usage, "values") || %{}, totals, fn {key, amount}, values ->
          if is_number(amount),
            do: Map.update(values, to_string(key), amount, &(&1 + amount)),
            else: values
        end)
      end)

    %{
      "status" => summary_status(available, additive, excluded),
      "additive_task_count" => length(additive),
      "excluded_task_count" => excluded,
      "unavailable_task_count" => length(usages) - length(available),
      "values" => totals
    }
  end

  defp new!(status, scope, additive, values),
    do: Zoi.parse!(@schema, %{status: status, scope: scope, additive: additive, values: values})

  defp put_total_tokens(%{"total_tokens" => total} = values) when is_number(total),
    do: values

  defp put_total_tokens(values) do
    input = Map.get(values, "input_tokens")
    output = Map.get(values, "output_tokens")

    if is_number(input) or is_number(output) do
      Map.put(values, "total_tokens", (input || 0) + (output || 0))
    else
      values
    end
  end

  defp summary_status([], _additive, _excluded), do: "unavailable"
  defp summary_status(_available, [], _excluded), do: "non_additive"
  defp summary_status(_available, _additive, excluded) when excluded > 0, do: "partial"
  defp summary_status(_available, _additive, _excluded), do: "available"

  defp value(map, key), do: Map.get(map, key, Map.get(map, String.to_existing_atom(key)))
end
