defmodule Hancho.ProviderContract do
  @moduledoc "Validates Hancho settings against the pinned Jido.Harness provider contract."

  @providers %{
    "amp" => :amp,
    "claude" => :claude,
    "codex" => :codex,
    "gemini" => :gemini,
    "grok" => :grok,
    "kimi" => :kimi,
    "opencode" => :opencode,
    "pi" => :pi,
    "zai" => :zai
  }

  @sandbox_modes %{
    "default" => :default,
    "read_only" => :read_only,
    "workspace_write" => :workspace_write,
    "unrestricted" => :unrestricted
  }

  @reasoning_efforts %{
    "low" => :low,
    "medium" => :medium,
    "high" => :high,
    "xhigh" => :xhigh
  }

  @spec providers() :: %{String.t() => atom()}
  def providers, do: @providers

  @spec provider(String.t()) :: {:ok, atom()} | {:error, String.t()}
  def provider(name) do
    case Map.fetch(@providers, name) do
      {:ok, provider} -> {:ok, provider}
      :error -> {:error, "Unknown Jido.Harness provider: #{name}"}
    end
  end

  @spec validate(atom(), map()) :: :ok | {:error, String.t()}
  def validate(provider, params) when is_atom(provider) and is_map(params) do
    with {:ok, spec} <- provider_spec(provider),
         :ok <- validate_cli(spec, Map.get(params, :cli)),
         :ok <- validate_model(spec, Map.get(params, :model)),
         :ok <- validate_reasoning(spec, Map.get(params, :reasoning_effort)),
         :ok <- validate_extra_args(spec, Map.get(params, :extra_args, [])),
         :ok <- validate_sandbox(spec, Map.get(params, :sandbox_mode)) do
      :ok
    end
  end

  defp provider_spec(provider) do
    case Jido.Harness.Registry.spec(provider) do
      {:ok, spec} ->
        {:ok, spec}

      {:error, reason} ->
        {:error, "Cannot load the #{provider} Harness contract: #{inspect(reason)}"}
    end
  end

  defp validate_cli(_spec, nil), do: :ok

  defp validate_cli(spec, _path) do
    require_provider_option(spec, :cli_path, "a CLI executable override")
  end

  defp validate_model(_spec, nil), do: :ok

  defp validate_model(spec, _model),
    do: require_normalized_option(spec, :model, "model selection")

  defp validate_reasoning(_spec, nil), do: :ok

  defp validate_reasoning(spec, effort) do
    with :ok <- require_normalized_option(spec, :reasoning_effort, "reasoning effort") do
      with {:ok, value} <- Map.fetch(@reasoning_efforts, effort) do
        case Map.get(spec.normalized_values, :reasoning_effort) do
          nil ->
            :ok

          values ->
            if(value in values,
              do: :ok,
              else: unsupported_value(spec, "reasoning effort", effort)
            )
        end
      else
        :error -> unsupported_value(spec, "reasoning effort", effort)
      end
    end
  end

  defp validate_extra_args(_spec, []), do: :ok

  defp validate_extra_args(spec, _args) do
    require_provider_option(spec, :extra_args, "extra arguments")
  end

  defp validate_sandbox(_spec, nil), do: :ok
  defp validate_sandbox(_spec, "default"), do: :ok

  defp validate_sandbox(spec, mode) do
    with :ok <- require_normalized_option(spec, :sandbox_mode, "sandbox mode") do
      with {:ok, value} <- Map.fetch(@sandbox_modes, mode) do
        case Map.get(spec.normalized_values, :sandbox_mode) do
          nil ->
            :ok

          values ->
            if(value in values, do: :ok, else: unsupported_value(spec, "sandbox mode", mode))
        end
      else
        :error -> unsupported_value(spec, "sandbox mode", mode)
      end
    end
  end

  defp require_normalized_option(spec, option, label) do
    if option in spec.normalized_options,
      do: :ok,
      else: {:error, "The #{spec.provider} Harness adapter does not support #{label}."}
  end

  defp require_provider_option(spec, option, label) do
    if option in spec.provider_options,
      do: :ok,
      else: {:error, "The #{spec.provider} Harness adapter does not support #{label}."}
  end

  defp unsupported_value(spec, label, value) do
    {:error, "The #{spec.provider} Harness adapter does not support #{label} #{value}."}
  end
end
