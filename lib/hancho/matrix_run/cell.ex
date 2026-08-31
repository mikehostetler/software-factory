defmodule Hancho.MatrixRun.Cell do
  @moduledoc "Parses one selected Harness provider and model combination."

  @spec parse_many([String.t()]) :: {:ok, [map()]} | {:error, String.t()}
  def parse_many(specifications) when is_list(specifications) do
    specifications
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {specification, position}, {:ok, cells} ->
      case parse(specification, position) do
        {:ok, cell} -> {:cont, {:ok, [cell | cells]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, cells} -> validate_unique(Enum.reverse(cells))
      error -> error
    end
  end

  def parse_many(_specifications), do: {:error, "Matrix cells must be a list."}

  defp parse(specification, position) when is_binary(specification) do
    case String.split(specification, "=", parts: 2) do
      [provider] -> build(provider, nil, position)
      [provider, model] -> build(provider, model, position)
    end
  end

  defp parse(_specification, _position), do: {:error, "Each matrix cell must be text."}

  defp build(provider, model, position) do
    provider = String.trim(provider)
    model = normalize_model(model)

    cond do
      provider == "" ->
        {:error, "A matrix cell has no provider."}

      model == :invalid ->
        {:error, "Matrix cell #{provider}= has no model."}

      true ->
        case Hancho.Actions.Implement.provider(provider) do
          {:ok, provider_atom} ->
            {:ok,
             %{
               id: cell_id(position, provider, model),
               position: position,
               provider: provider_atom,
               provider_name: provider,
               requested_model: model
             }}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp normalize_model(nil), do: nil

  defp normalize_model(model) when is_binary(model) do
    case String.trim(model) do
      "" -> :invalid
      value -> value
    end
  end

  defp validate_unique(cells) do
    keys = Enum.map(cells, &{&1.provider, &1.requested_model})

    if length(keys) == length(Enum.uniq(keys)) do
      {:ok, cells}
    else
      {:error, "Matrix cells must be unique."}
    end
  end

  defp cell_id(position, provider, model) do
    suffix = if is_binary(model), do: "-#{slug(model)}", else: "-default"
    position = position |> Integer.to_string() |> String.pad_leading(3, "0")
    "#{position}-#{slug(provider)}#{suffix}"
  end

  defp slug(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> String.slice(0, 48)
    |> case do
      "" -> "value"
      result -> result
    end
  end
end
