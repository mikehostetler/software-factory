defmodule Hancho.Workflow.Compiler do
  @moduledoc "Validates a workflow and its local dependencies before execution."

  alias Hancho.Workflow.Params

  @spec compile(Hancho.Project.t(), Hancho.Workflow.Definition.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def compile(project, definition, input, options \\ []) do
    registry = Keyword.get(options, :registry, Hancho.Workflow.Registry)

    with :ok <- validate_references(definition.steps, input),
         {:ok, steps} <- compile_steps(project, definition, registry, options),
         :ok <- validate_workspace_contract(definition.steps),
         :ok <- validate_repair_contract(definition.steps) do
      {:ok,
       %{
         workflow: definition.name,
         version: definition.version,
         steps: steps,
         provider: provider_summary(steps),
         model: model_summary(steps),
         executables: collect(steps, :executable),
         prompt_files: collect(steps, :prompt_file)
       }}
    end
  end

  defp validate_repair_contract(steps) do
    steps
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {step, position}, :ok ->
      if step.on_error do
        workspaces =
          steps
          |> Enum.take(position)
          |> Enum.count(&workspace_action?/1)

        case workspaces do
          1 ->
            {:cont, :ok}

          0 ->
            {:halt, {:error, {:workflow_compile_failed, step.name, :workspace_not_declared}}}

          _count ->
            {:halt,
             {:error, {:workflow_compile_failed, step.name, :multiple_workspaces_declared}}}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  defp validate_workspace_contract(steps) do
    case Enum.find_index(steps, &(&1.action == "Hancho.Actions.Implement")) do
      nil ->
        :ok

      implement_position ->
        workspaces =
          steps
          |> Enum.with_index()
          |> Enum.filter(fn {step, position} ->
            position < implement_position and workspace_action?(step)
          end)

        case workspaces do
          [{_step, _position}] ->
            :ok

          [] ->
            implement = Enum.at(steps, implement_position)
            {:error, {:workflow_compile_failed, implement.name, :workspace_not_declared}}

          _multiple ->
            implement = Enum.at(steps, implement_position)
            {:error, {:workflow_compile_failed, implement.name, :multiple_workspaces_declared}}
        end
    end
  end

  defp compile_steps(project, definition, registry, options) do
    definition.steps
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {step, position}, {:ok, compiled} ->
      params = Hancho.Workflow.RoleResolver.params(definition, step)

      with {:ok, action} <- registry.fetch(step.action),
           :ok <- validate_action_params(action, params),
           {:ok, environment} <- validate_environment(project, action, params, options),
           {:ok, repair_environment} <- validate_repair_environment(step, options) do
        summary = %{
          position: position,
          name: step.name,
          action: step.action,
          module: action,
          environment: Map.merge(environment, repair_environment)
        }

        {:cont, {:ok, [summary | compiled]}}
      else
        {:error, reason} -> {:halt, {:error, {:workflow_compile_failed, step.name, reason}}}
      end
    end)
    |> case do
      {:ok, compiled} -> {:ok, Enum.reverse(compiled)}
      error -> error
    end
  end

  defp validate_repair_environment(%{on_error: nil}, _options), do: {:ok, %{}}

  defp validate_repair_environment(%{on_error: policy}, options) do
    with {:ok, provider} <- Hancho.Actions.Implement.provider(policy.repair_with),
         :ok <- maybe_provider_ready(provider, options) do
      {:ok, %{repair_provider: policy.repair_with}}
    end
  end

  defp maybe_provider_ready(provider, options) do
    if Keyword.get(options, :validate_environment, true),
      do: provider_ready(provider, options),
      else: :ok
  end

  defp validate_action_params(action, params) do
    if is_atom(action) do
      Code.ensure_loaded(action)
    end

    if is_atom(action) and function_exported?(action, :schema, 0) do
      fields = action.schema().fields |> Map.new()
      allowed = Map.keys(fields)
      normalized = normalize_param_keys(params, allowed)
      unknown = Map.keys(normalized) -- allowed

      missing =
        Enum.filter(fields, fn {key, schema} ->
          required?(schema) and not Map.has_key?(normalized, key)
        end)

      cond do
        unknown != [] ->
          {:error, {:unknown_action_params, Enum.sort(unknown)}}

        missing != [] ->
          {:error, {:missing_action_params, missing |> Enum.map(&elem(&1, 0)) |> Enum.sort()}}

        true ->
          validate_literal_params(fields, normalized)
      end
    else
      :ok
    end
  end

  defp validate_literal_params(fields, params) do
    Enum.reduce_while(params, :ok, fn {key, value}, :ok ->
      if contains_reference?(value) do
        {:cont, :ok}
      else
        case Zoi.parse(Map.fetch!(fields, key), value) do
          {:ok, _value} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:invalid_action_param, key, reason}}}
        end
      end
    end)
  end

  defp validate_environment(project, action, params, options) do
    if Keyword.get(options, :validate_environment, true) do
      do_validate_environment(project, action, params, options)
    else
      {:ok, %{}}
    end
  end

  defp do_validate_environment(_project, Hancho.Actions.Implement, params, options) do
    with {:ok, provider_name} <- literal_param(params, "provider"),
         {:ok, provider} <- Hancho.Actions.Implement.provider(provider_name),
         {:ok, cli} <- optional_literal_param(params, "cli"),
         {:ok, model} <- optional_literal_param(params, "model"),
         :ok <- provider_environment(provider, cli, options) do
      {:ok, %{provider: provider_name, cli: cli, model: model}}
    end
  end

  defp do_validate_environment(_project, Hancho.Actions.Verify, params, _options) do
    with {:ok, executable} <- literal_param(params, "executable"),
         {:ok, path} <- executable_path(executable) do
      {:ok, %{executable: path}}
    end
  end

  defp do_validate_environment(project, Hancho.Actions.RenderPrompt, params, _options) do
    prompt = param(params, "prompt")
    prompt_file = param(params, "prompt_file")

    cond do
      is_binary(prompt) and not contains_reference?(prompt) and is_nil(prompt_file) ->
        {:ok, %{prompt: :inline}}

      is_binary(prompt_file) and not contains_reference?(prompt_file) and is_nil(prompt) ->
        validate_prompt_file(project, prompt_file)

      contains_reference?(prompt) or contains_reference?(prompt_file) ->
        {:ok, %{prompt: :dynamic}}

      true ->
        {:error, :invalid_prompt_source}
    end
  end

  defp do_validate_environment(_project, _action, _params, _options), do: {:ok, %{}}

  defp provider_ready(provider, options) do
    harness = options |> Keyword.get(:services, %{}) |> Map.get(:harness, Hancho.Harness)

    if function_exported?(harness, :status, 1) do
      case harness.status(provider) do
        {:ok, status} ->
          if Jido.Harness.ProviderStatus.ready?(status),
            do: :ok,
            else: {:error, {:provider_not_ready, provider, status}}

        {:error, reason} ->
          {:error, {:provider_status_failed, provider, reason}}
      end
    else
      :ok
    end
  end

  defp provider_environment(_provider, cli, _options) when is_binary(cli) do
    case executable_path(cli) do
      {:ok, _path} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp provider_environment(provider, nil, options), do: provider_ready(provider, options)

  defp validate_prompt_file(project, prompt_file) do
    base = Path.join(project.hancho_dir, "prompts")

    with true <- Path.type(prompt_file) == :relative || {:error, :unsafe_prompt_path},
         {:ok, relative} <- Path.safe_relative(prompt_file, base),
         path = Path.join(base, relative),
         true <- File.regular?(path) || {:error, {:prompt_file_not_found, prompt_file}} do
      {:ok, %{prompt_file: prompt_file}}
    end
  end

  defp validate_references(steps, input) do
    steps
    |> Enum.reduce_while({:ok, MapSet.new(), MapSet.new()}, fn step, {:ok, prior, artifacts} ->
      case validate_param_references(step.params, input, prior, artifacts) do
        :ok ->
          artifacts = if step.produces, do: MapSet.put(artifacts, step.produces), else: artifacts
          {:cont, {:ok, MapSet.put(prior, step.name), artifacts}}

        {:error, reason} ->
          {:halt, {:error, {:workflow_compile_failed, step.name, reason}}}
      end
    end)
    |> case do
      {:ok, _prior, _artifacts} -> :ok
      error -> error
    end
  end

  defp validate_param_references(value, input, prior, artifacts) when is_binary(value) do
    if String.starts_with?(value, "$"),
      do: validate_reference(value, input, prior, artifacts),
      else: :ok
  end

  defp validate_param_references(values, input, prior, artifacts) when is_list(values) do
    reduce_references(values, input, prior, artifacts)
  end

  defp validate_param_references(values, input, prior, artifacts) when is_map(values) do
    values |> Map.values() |> reduce_references(input, prior, artifacts)
  end

  defp validate_param_references(_value, _input, _prior, _artifacts), do: :ok

  defp reduce_references(values, input, prior, artifacts) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case validate_param_references(value, input, prior, artifacts) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_reference(reference, input, prior, artifacts) do
    path = reference |> String.trim_leading("$") |> String.split(".")

    case path do
      ["input" | rest] ->
        validate_input_reference(input, rest, reference)

      ["run", "id"] ->
        :ok

      ["steps", name | rest] when rest != [] ->
        if MapSet.member?(prior, name),
          do: :ok,
          else: {:error, {:unavailable_step_reference, reference}}

      ["artifacts", name | rest] when rest != [] ->
        if MapSet.member?(artifacts, name),
          do: :ok,
          else: {:error, {:unavailable_artifact_reference, reference}}

      _other ->
        {:error, {:invalid_parameter_reference, reference}}
    end
  end

  defp validate_input_reference(input, path, reference) do
    case Params.resolve("$input" <> if(path == [], do: "", else: "." <> Enum.join(path, ".")), %{
           "input" => input
         }) do
      {:ok, _value} -> :ok
      {:error, _reason} -> {:error, {:missing_input_reference, reference}}
    end
  end

  defp normalize_param_keys(params, allowed) do
    strings = Map.new(allowed, &{Atom.to_string(&1), &1})

    Map.new(params, fn
      {key, value} when is_binary(key) -> {Map.get(strings, key, key), value}
      pair -> pair
    end)
  end

  defp required?(%Zoi.Types.Default{}), do: false
  defp required?(schema), do: schema.meta.required == true

  defp contains_reference?(value) when is_binary(value), do: String.starts_with?(value, "$")

  defp contains_reference?(value) when is_list(value),
    do: Enum.any?(value, &contains_reference?/1)

  defp contains_reference?(value) when is_map(value),
    do: value |> Map.values() |> Enum.any?(&contains_reference?/1)

  defp contains_reference?(_value), do: false

  defp literal_param(params, key) do
    case param(params, key) do
      value when is_binary(value) ->
        if contains_reference?(value),
          do: {:error, {:dynamic_compile_param, key}},
          else: {:ok, value}

      _value ->
        {:error, {:missing_compile_param, key}}
    end
  end

  defp optional_literal_param(params, key) do
    case param(params, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        if contains_reference?(value),
          do: {:error, {:dynamic_compile_param, key}},
          else: {:ok, value}

      _value ->
        {:error, {:invalid_compile_param, key}}
    end
  end

  defp param(params, key) do
    Enum.find_value(params, fn
      {param_key, value} when is_atom(param_key) -> if Atom.to_string(param_key) == key, do: value
      {^key, value} -> value
      _pair -> nil
    end)
  end

  defp executable_path(path) do
    cond do
      Path.type(path) == :absolute and File.regular?(path) -> {:ok, path}
      executable = System.find_executable(path) -> {:ok, executable}
      true -> {:error, {:executable_not_found, path}}
    end
  end

  defp provider_summary(steps) do
    Enum.find_value(steps, fn step -> step.environment[:provider] end)
  end

  defp model_summary(steps) do
    Enum.find_value(steps, fn step -> step.environment[:model] end)
  end

  defp collect(steps, key) do
    steps
    |> Enum.flat_map(fn step -> if value = step.environment[key], do: [value], else: [] end)
    |> Enum.uniq()
  end

  defp workspace_action?(step) do
    step.action in ["Hancho.Actions.CreateWorktree", "Hancho.Actions.UseRepository"]
  end
end
