defmodule Hancho.ModelDiscovery do
  @moduledoc "Discovers model evidence for CLI providers configured in local workflows."

  @smoke_prompt "Reply with exactly HANCHO_MODEL_OK. Do not use tools or inspect files."
  @smoke_timeout_ms 120_000
  @model_output_limit 4_194_304
  @disabled_tools [
    "Agent",
    "AskUserQuestion",
    "Bash",
    "Edit",
    "EnterPlanMode",
    "ExitPlanMode",
    "Glob",
    "Grep",
    "KillShell",
    "LSP",
    "ListMcpResourcesTool",
    "MultiEdit",
    "NotebookEdit",
    "NotebookRead",
    "Read",
    "Skill",
    "Task",
    "TaskCreate",
    "TaskGet",
    "TaskList",
    "TaskOutput",
    "TaskStop",
    "TaskUpdate",
    "TodoRead",
    "TodoWrite",
    "WebFetch",
    "WebSearch",
    "Write",
    "bash",
    "edit",
    "find",
    "grep",
    "ls",
    "read",
    "write"
  ]

  @model_commands %{
    "amp" => ["plugins", "show-agent-options", "--json"],
    "codex" => ["debug", "models"],
    "grok" => ["models"],
    "kimi" => ["provider", "list", "--json"],
    "opencode" => ["models"],
    "pi" => ["--list-models"]
  }

  @spec discover(Hancho.Project.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def discover(project, options \\ []) do
    harness = Keyword.get(options, :harness, Jido.Harness)
    start_harness = Keyword.get(options, :start_harness, &Hancho.Harness.ensure_started/0)

    with {:ok, sources} <- configured_sources(project, options),
         :ok <- start_discovery_harness(start_harness) do
      specs = harness.providers() |> Map.new(&{Atom.to_string(&1.provider), &1})

      providers =
        sources
        |> Enum.group_by(&{&1["provider"], &1["cli"]})
        |> Enum.sort_by(fn {{provider, cli}, _sources} -> {provider, cli || ""} end)
        |> Enum.map(fn {{provider, cli}, provider_sources} ->
          discover_provider(provider, cli, provider_sources, specs[provider], project, options)
        end)

      {:ok,
       %{
         "providers" => providers,
         "schema_version" => 1,
         "smoke_test_enabled" => Keyword.get(options, :smoke, false),
         "source" => "repository_workflows"
       }}
    end
  rescue
    _error -> {:error, :model_discovery_failed}
  catch
    _kind, _reason -> {:error, :model_discovery_failed}
  end

  @spec format(map()) :: String.t()
  def format(%{"providers" => providers} = report) do
    header = [
      "Hancho models",
      "Configured provider targets: #{length(providers)}",
      "Smoke tests: #{if(report["smoke_test_enabled"], do: "enabled", else: "disabled")}"
    ]

    sections = Enum.flat_map(providers, &["" | format_provider(&1)])
    Enum.join(header ++ sections, "\n")
  end

  @doc false
  @spec parse_models(String.t(), String.t()) :: {:ok, [String.t()]} | {:error, :invalid_output}
  def parse_models(provider, output) when provider in ["amp", "codex"] do
    with {:ok, values} when is_map(values) <- Jason.decode(strip_ansi(output)),
         models when is_list(models) <- values["models"] do
      key = if provider == "codex", do: ["slug", "model", "id"], else: ["id", "model", "name"]

      models =
        models
        |> Enum.reject(fn model ->
          provider == "codex" and is_map(model) and model["visibility"] in ["hide", "hidden"]
        end)
        |> Enum.flat_map(&model_value(&1, key))
        |> normalize_models()

      {:ok, models}
    else
      _reason -> {:error, :invalid_output}
    end
  end

  def parse_models("kimi", output) do
    with {:ok, values} when is_map(values) <- Jason.decode(strip_ansi(output)),
         true <- kimi_catalog?(values) do
      models =
        model_collections(values)
        |> Enum.flat_map(&collection_models/1)
        |> normalize_models()

      {:ok, models}
    else
      _reason -> {:error, :invalid_output}
    end
  end

  def parse_models("grok", output) do
    lines = output |> strip_ansi() |> String.split("\n")

    case Enum.split_while(lines, &(String.trim(&1) != "Available models:")) do
      {_before, [_heading | lines]} ->
        models =
          lines
          |> Enum.take_while(fn line -> Regex.match?(~r/^\s*[\*\-]\s+/, line) end)
          |> Enum.map(fn line ->
            line
            |> String.replace(~r/^\s*[\*\-]\s+/, "")
            |> String.replace(~r/\s+\(default\)\s*$/, "")
          end)
          |> normalize_models()

        {:ok, models}

      {_before, []} ->
        {:error, :invalid_output}
    end
  end

  def parse_models("opencode", output) do
    lines =
      output
      |> strip_ansi()
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)

    models =
      lines
      |> Enum.filter(&Regex.match?(~r/^[A-Za-z0-9._-]+\/[A-Za-z0-9._:\/@+-]+$/, &1))
      |> normalize_models()

    if lines == [] or models != [], do: {:ok, models}, else: {:error, :invalid_output}
  end

  def parse_models("pi", output) do
    clean = strip_ansi(output)
    lines = String.split(clean, "\n", trim: true)
    header = Enum.find_index(lines, &Regex.match?(~r/^provider\s+model\s+/i, String.trim(&1)))

    cond do
      is_integer(header) ->
        models =
          lines
          |> Enum.drop(header + 1)
          |> Enum.flat_map(fn line ->
            case Regex.split(~r/\s{2,}/, String.trim(line), trim: true) do
              [provider, model | _rest] ->
                [if(String.contains?(model, "/"), do: model, else: "#{provider}/#{model}")]

              _columns ->
                []
            end
          end)
          |> normalize_models()

        {:ok, models}

      lines == [] or String.contains?(String.downcase(clean), "no models available") ->
        {:ok, []}

      true ->
        {:error, :invalid_output}
    end
  end

  def parse_models(_provider, _output), do: {:error, :invalid_output}

  defp configured_sources(project, options) do
    loader = Keyword.get(options, :workflow_loader, Hancho.Workflow.Loader)

    project.workflows_path
    |> Path.join("*.yaml")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, sources} ->
      case loader.load_path(path) do
        {:ok, definition} ->
          workflow_sources = definition_sources(definition, Path.basename(path))
          {:cont, {:ok, sources ++ workflow_sources}}

        {:error, _reason} ->
          {:halt, {:error, {:workflow_model_configuration_failed, Path.basename(path)}}}
      end
    end)
  end

  defp definition_sources(definition, workflow) do
    roles =
      Enum.map(definition.roles, fn {name, role} ->
        source(
          workflow,
          "role:#{name}",
          role.provider,
          role.cli,
          role.model,
          role.reasoning_effort
        )
      end)

    steps =
      definition.steps
      |> Enum.filter(&(&1.action == "Hancho.Actions.Implement"))
      |> Enum.map(fn step ->
        params = Hancho.Workflow.RoleResolver.params(definition, step)

        source(
          workflow,
          "step:#{step.name}",
          param(params, "provider"),
          param(params, "cli"),
          param(params, "model"),
          param(params, "reasoning_effort")
        )
      end)

    repairs =
      definition.steps
      |> Enum.filter(& &1.on_error)
      |> Enum.map(fn step ->
        source(workflow, "repair:#{step.name}", step.on_error.repair_with, nil, nil, nil)
      end)

    (roles ++ steps ++ repairs)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp source(_workflow, _location, provider, _cli, _model, _reasoning)
       when not is_binary(provider) or provider == "",
       do: nil

  defp source(workflow, location, provider, cli, model, reasoning) do
    %{
      "cli" => cli,
      "location" => location,
      "model" => model,
      "provider" => provider,
      "reasoning_effort" => reasoning,
      "workflow" => workflow
    }
  end

  defp discover_provider(provider, configured_cli, sources, nil, _project, _options) do
    base_report(provider, configured_cli, sources)
    |> Map.merge(%{
      "authentication" => "unknown",
      "cli" => %{
        "compatible" => nil,
        "installed" => false,
        "path" => configured_cli,
        "version" => nil
      },
      "model_discovery" => %{
        "status" => "unsupported",
        "detail" => "Provider is not registered in Harness."
      },
      "smoke_tests" => smoke_not_run(sources, "Provider is not registered in Harness."),
      "supported_reasoning_levels" => []
    })
  end

  defp discover_provider(provider, configured_cli, sources, spec, project, options) do
    harness = Keyword.get(options, :harness, Jido.Harness)
    provider_status = provider_status(harness, spec.provider)
    executable = executable(configured_cli, provider_status, spec)
    status = applicable_status(provider_status, configured_cli, executable)

    installed =
      executable != nil and (is_nil(configured_cli) or executable_available?(executable))

    model_discovery = discover_cli_models(provider, executable, installed, project, options)
    reported_authentication = authentication(status, auth_hint(provider, model_discovery))

    smoke_tests =
      smoke_tests(spec, executable, installed, sources, reported_authentication, project, options)

    authentication = authentication_after_smoke(reported_authentication, smoke_tests)

    base_report(provider, configured_cli, sources)
    |> Map.merge(%{
      "authentication" => authentication,
      "cli" => %{
        "compatible" => value(status, :compatible),
        "installed" => installed,
        "path" => executable || configured_cli,
        "version" => value(status, :version)
      },
      "model_discovery" => Map.drop(model_discovery, ["authentication_hint", "models"]),
      "models" => %{
        "cli_reported" => model_discovery["models"],
        "smoke_accepted" => accepted_models(smoke_tests),
        "user_configured" => configured_models(sources)
      },
      "smoke_tests" => smoke_tests,
      "supported_reasoning_levels" => reasoning_levels(spec)
    })
  end

  defp base_report(provider, configured_cli, sources) do
    %{
      "configured_cli" => configured_cli,
      "configuration_sources" => Enum.sort_by(sources, &{&1["workflow"], &1["location"]}),
      "models" => %{
        "cli_reported" => [],
        "smoke_accepted" => [],
        "user_configured" => configured_models(sources)
      },
      "provider" => provider
    }
  end

  defp provider_status(harness, provider) do
    case harness.status(provider) do
      {:ok, status} -> status
      _result -> nil
    end
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  defp applicable_status(status, nil, _executable), do: status

  defp applicable_status(status, _configured_cli, executable) do
    if executable != nil and executable == value(status, :executable), do: status
  end

  defp executable(configured_cli, _status, _spec) when is_binary(configured_cli) do
    resolve_executable(configured_cli)
  end

  defp executable(nil, status, spec) do
    value(status, :executable) || resolve_executable(spec.executable)
  end

  defp resolve_executable(path) do
    System.find_executable(path)
  end

  defp executable_available?(path), do: resolve_executable(path) != nil

  defp discover_cli_models(provider, _executable, _installed, _project, _options)
       when not is_map_key(@model_commands, provider) do
    %{
      "models" => [],
      "status" => "unsupported",
      "detail" => "This CLI has no supported non-interactive model-list command."
    }
  end

  defp discover_cli_models(_provider, _executable, false, _project, _options) do
    %{"models" => [], "status" => "failed", "detail" => "CLI executable is not available."}
  end

  defp discover_cli_models(provider, executable, true, project, options) do
    command = Keyword.get(options, :command, Hancho.Command)

    case command.run(executable, @model_commands[provider],
           cwd: project.root,
           timeout: 30_000,
           capture_limit: @model_output_limit
         ) do
      {:ok, %{exit_status: 0, stdout_truncated: false} = result} ->
        case parse_models(provider, result.stdout) do
          {:ok, models} ->
            %{
              "authentication_hint" => output_authentication(provider, command_output(result)),
              "detail" => if(models == [], do: "CLI reported no models.", else: nil),
              "models" => models,
              "status" => if(models == [], do: "empty", else: "reported")
            }

          {:error, :invalid_output} ->
            %{
              "authentication_hint" => output_authentication(provider, command_output(result)),
              "models" => [],
              "status" => "failed",
              "detail" => "CLI model output was not recognized."
            }
        end

      {:ok, %{stdout_truncated: true} = result} ->
        failed_model_discovery(provider, result, "CLI model output exceeded the capture limit.")

      {:ok, %{exit_status: exit_status} = result} ->
        failed_model_discovery(
          provider,
          result,
          "CLI model command exited with status #{exit_status}."
        )

      {:error, _reason} ->
        %{"models" => [], "status" => "failed", "detail" => "CLI model command did not complete."}
    end
  end

  defp smoke_tests(spec, executable, installed, sources, authentication, project, options) do
    models = configured_models(sources)

    cond do
      models == [] ->
        []

      not Keyword.get(options, :smoke, false) ->
        smoke_not_run(sources, "Smoke tests were disabled.")

      not installed or is_nil(executable) ->
        smoke_not_run(sources, "CLI executable is not available.")

      authentication == "unauthenticated" ->
        smoke_not_run(sources, "Provider is not authenticated.")

      :model not in spec.normalized_options ->
        smoke_not_run(sources, "Harness cannot request a model for this provider.")

      not read_only_supported?(spec) ->
        smoke_not_run(sources, "Harness cannot enforce a read-only smoke test for this provider.")

      true ->
        Enum.map(models, &run_smoke(spec, executable, &1, project, options))
    end
  end

  defp run_smoke(spec, executable, model, project, options) do
    harness = Keyword.get(options, :harness, Jido.Harness)
    configured_cli = if executable == spec.executable, do: nil, else: executable

    case create_smoke_directory(project, spec.provider, model) do
      {:ok, directory} ->
        try do
          run_options = smoke_options(spec, configured_cli, directory, model)

          case harness.run(spec.provider, @smoke_prompt, run_options) do
            {:ok, result} -> smoke_result(model, result)
            {:error, _reason} -> rejected_smoke(model, "Provider rejected the smoke request.")
          end
        rescue
          _error -> rejected_smoke(model, "Provider smoke request did not complete.")
        catch
          _kind, _reason -> rejected_smoke(model, "Provider smoke request did not complete.")
        after
          File.rm_rf(directory)
        end

      {:error, _reason} ->
        rejected_smoke(model, "A private smoke-test directory could not be created.")
    end
  end

  defp smoke_options(spec, configured_cli, directory, model) do
    security = Hancho.ProviderSecurity.options(spec.provider)

    provider_options =
      security.provider_options
      |> Map.merge(smoke_provider_options(spec.provider))
      |> maybe_put(:cli_path, configured_cli)

    [
      cwd: directory,
      model: model,
      approval_mode: safe_approval(spec),
      sandbox_mode: :read_only,
      runtime_timeout_ms: @smoke_timeout_ms,
      idle_timeout_ms: @smoke_timeout_ms,
      await_timeout: @smoke_timeout_ms + 5_000,
      provider_options: provider_options
    ]
    |> smoke_tool_options(spec)
    |> maybe_option(:max_turns, 1, :max_turns in spec.normalized_options)
  end

  defp smoke_provider_options(:codex) do
    %{network_access_enabled: false, skip_git_repo_check: true}
  end

  defp smoke_provider_options(:pi) do
    %{
      no_context_files: true,
      no_extensions: true,
      no_session: true,
      no_skills: true,
      project_trust: :deny
    }
  end

  defp smoke_provider_options(_provider), do: %{}

  defp smoke_tool_options(options, %{provider: provider} = spec) when provider in [:grok, :pi] do
    maybe_option(options, :allowed_tools, [], :allowed_tools in spec.normalized_options)
  end

  defp smoke_tool_options(options, spec) do
    cond do
      :disallowed_tools in spec.normalized_options ->
        Keyword.put(options, :disallowed_tools, @disabled_tools)

      :allowed_tools in spec.normalized_options ->
        Keyword.put(options, :allowed_tools, ["__hancho_no_tools__"])

      true ->
        options
    end
  end

  defp smoke_result(requested_model, result) do
    effective_model = effective_model(result)
    response = value(result, :text)
    tool_use_observed = tool_use_observed?(result)

    completed =
      value(result, :status) in [:completed, "completed"] and
        is_binary(response) and String.trim(response) == "HANCHO_MODEL_OK" and
        not tool_use_observed

    accepted = completed and effective_model in [nil, requested_model]

    status =
      cond do
        accepted -> "accepted"
        completed and is_binary(effective_model) -> "fallback_observed"
        true -> "rejected"
      end

    %{
      "accepted" => accepted,
      "detail" =>
        if(tool_use_observed,
          do: "Provider used a tool during the smoke request.",
          else: smoke_detail(status)
        ),
      "effective_model" => effective_model,
      "effective_model_observed" => is_binary(effective_model),
      "requested_model" => requested_model,
      "status" => status,
      "tool_use_observed" => tool_use_observed
    }
  end

  defp rejected_smoke(model, detail) do
    %{
      "accepted" => false,
      "detail" => detail,
      "effective_model" => nil,
      "effective_model_observed" => false,
      "requested_model" => model,
      "status" => "rejected",
      "tool_use_observed" => false
    }
  end

  defp smoke_not_run(sources, detail) do
    sources
    |> configured_models()
    |> Enum.map(fn model ->
      %{
        "accepted" => false,
        "detail" => detail,
        "effective_model" => nil,
        "effective_model_observed" => false,
        "requested_model" => model,
        "status" => "not_run",
        "tool_use_observed" => false
      }
    end)
  end

  defp create_smoke_directory(project, provider, model) do
    digest = :crypto.hash(:sha256, model) |> Base.encode16(case: :lower) |> binary_part(0, 12)
    random = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

    directory =
      Path.join(
        System.tmp_dir!(),
        "hancho-model-smoke-#{Path.basename(project.root)}-#{provider}-#{digest}-#{random}"
      )

    case File.mkdir(directory) do
      :ok ->
        case File.chmod(directory, 0o700) do
          :ok ->
            {:ok, directory}

          {:error, _reason} = error ->
            File.rmdir(directory)
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp effective_model(result) do
    result
    |> value(:events, [])
    |> Enum.find_value(fn event ->
      if value(event, :type) in [:run_started, "run_started"] do
        payload = value(event, :payload, %{})

        case payload["model"] || payload[:model] do
          model when is_binary(model) and byte_size(model) <= 256 ->
            model = String.trim(model)
            if model_name?(model), do: model

          _model ->
            nil
        end
      end
    end)
  end

  defp tool_use_observed?(result) do
    result
    |> value(:events, [])
    |> Enum.any?(
      &(value(&1, :type) in [
          :tool_call,
          "tool_call",
          :tool_result,
          "tool_result",
          :file_change,
          "file_change"
        ])
    )
  end

  defp accepted_models(tests) do
    tests
    |> Enum.filter(& &1["accepted"])
    |> Enum.map(& &1["requested_model"])
    |> normalize_models()
  end

  defp configured_models(sources) do
    sources
    |> Enum.map(& &1["model"])
    |> normalize_models()
  end

  defp reasoning_levels(spec) do
    if :reasoning_effort in spec.normalized_options do
      spec.normalized_values
      |> Map.get(:reasoning_effort, [])
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&to_string/1)
      |> Enum.uniq()
    else
      []
    end
  end

  defp safe_approval(spec) do
    accepted = Map.get(spec.normalized_values, :approval_mode)
    if is_list(accepted) and :prompt not in accepted, do: :default, else: :prompt
  end

  defp read_only_supported?(spec) do
    accepted = Map.get(spec.normalized_values, :sandbox_mode)

    :sandbox_mode in spec.normalized_options and
      (not is_list(accepted) or :read_only in accepted)
  end

  defp authentication(status, hint) do
    case hint do
      hint when hint in ["authenticated", "unauthenticated"] ->
        hint

      _hint ->
        case value(status, :authenticated) do
          true -> "authenticated"
          false -> "unauthenticated"
          _unknown -> "unknown"
        end
    end
  end

  defp authentication_after_smoke(authentication, smoke_tests) do
    if Enum.any?(smoke_tests, &(&1["status"] in ["accepted", "fallback_observed"])),
      do: "authenticated",
      else: authentication
  end

  defp auth_hint(_provider, model_discovery), do: model_discovery["authentication_hint"]

  defp output_authentication("grok", output) do
    output = String.downcase(output)

    cond do
      String.contains?(output, "not authenticated") -> "unauthenticated"
      String.contains?(output, "you are logged in with") -> "authenticated"
      true -> nil
    end
  end

  defp output_authentication("pi", output) do
    if String.contains?(String.downcase(output), "use /login"), do: "unauthenticated"
  end

  defp output_authentication(_provider, _output), do: nil

  defp model_collections(values) when is_map(values) do
    direct = Enum.map(["models", "modelAliases", "model_aliases", "aliases"], &values[&1])

    provider_models =
      values
      |> Map.get("providers", [])
      |> provider_values()
      |> Enum.flat_map(fn
        provider when is_map(provider) ->
          [
            provider["models"],
            provider["modelAliases"],
            provider["model_aliases"],
            provider["aliases"]
          ]

        _provider ->
          []
      end)

    Enum.reject(direct ++ provider_models, &is_nil/1)
  end

  defp kimi_catalog?(values) do
    Enum.any?(
      ["models", "providers", "modelAliases", "model_aliases", "aliases"],
      &Map.has_key?(values, &1)
    )
  end

  defp provider_values(values) when is_list(values), do: values
  defp provider_values(values) when is_map(values), do: Map.values(values)
  defp provider_values(_values), do: []

  defp collection_models(values) when is_list(values),
    do: Enum.flat_map(values, &model_value(&1, ["id", "model", "name"]))

  defp collection_models(values) when is_map(values) do
    if Enum.any?(["id", "model", "name"], &Map.has_key?(values, &1)) do
      model_value(values, ["id", "model", "name"])
    else
      Enum.flat_map(values, fn {name, value} ->
        if sensitive_key?(name) do
          []
        else
          model_value(value, ["id", "model", "name"]) ++
            if(model_name?(name), do: [name], else: [])
        end
      end)
    end
  end

  defp collection_models(_values), do: []

  defp model_value(value, _keys) when is_binary(value), do: [value]

  defp model_value(value, keys) when is_map(value) do
    Enum.find_value(keys, [], fn key ->
      case value[key] do
        model when is_binary(model) -> [model]
        _value -> nil
      end
    end)
  end

  defp model_value(_value, _keys), do: []

  defp model_name?(name),
    do:
      is_binary(name) and byte_size(name) <= 256 and
        Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9._:\/@+-]+$/, name)

  defp sensitive_key?(name) when is_binary(name) do
    normalized = name |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")

    normalized in [
      "api",
      "apikey",
      "apitoken",
      "auth",
      "authorization",
      "key",
      "refreshtoken",
      "sessiontoken",
      "token"
    ] or
      Enum.any?(
        ["accesstoken", "authtoken", "credential", "password", "privatekey", "secret"],
        &String.contains?(normalized, &1)
      )
  end

  defp sensitive_key?(_name), do: false

  defp normalize_models(models) do
    models
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.map(&String.trim/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp format_provider(provider) do
    models = provider["models"]
    discovery = provider["model_discovery"]

    [
      "Provider: #{provider["provider"]}",
      "  CLI: #{provider["cli"]["path"] || "not found"}",
      "  Installed: #{yes_no(provider["cli"]["installed"])}",
      "  Authentication: #{provider["authentication"]}",
      "  Supported reasoning levels: #{join_or_none(provider["supported_reasoning_levels"])}",
      "  CLI model discovery: #{discovery["status"]}#{detail(discovery["detail"])}",
      "  CLI-reported models: #{join_or_none(models["cli_reported"])}",
      "  User-configured models: #{join_or_none(models["user_configured"])}",
      "  Smoke-accepted models: #{join_or_none(models["smoke_accepted"])}"
    ] ++ format_smoke_tests(provider["smoke_tests"])
  end

  defp format_smoke_tests([]), do: ["  Smoke tests: none; no model was explicitly requested"]

  defp format_smoke_tests(tests) do
    ["  Smoke tests:"] ++
      Enum.map(tests, fn test ->
        effective = test["effective_model"] || "not observable"

        "    #{test["requested_model"]}: #{test["status"]}; effective model: #{effective}#{detail(test["detail"])}"
      end)
  end

  defp smoke_detail("accepted"), do: nil
  defp smoke_detail("fallback_observed"), do: "CLI used a different effective model."
  defp smoke_detail(_status), do: "Smoke request did not complete successfully."

  defp command_output(result),
    do: value(result, :stdout, "") <> "\n" <> value(result, :stderr, "")

  defp failed_model_discovery(provider, result, detail) do
    %{
      "authentication_hint" => output_authentication(provider, command_output(result)),
      "models" => [],
      "status" => "failed",
      "detail" => detail
    }
  end

  defp join_or_none([]), do: "none"
  defp join_or_none(values), do: Enum.join(values, ", ")
  defp detail(nil), do: ""
  defp detail(""), do: ""
  defp detail(value), do: " (#{value})"
  defp yes_no(true), do: "yes"
  defp yes_no(_value), do: "no"

  defp strip_ansi(value), do: String.replace(value, ~r/\e\[[0-?]*[ -\/]*[@-~]/, "")

  defp param(params, name),
    do: Enum.find_value(params, fn {key, value} -> if to_string(key) == name, do: value end)

  defp value(data, key, default \\ nil)
  defp value(nil, _key, default), do: default
  defp value(data, key, default), do: Map.get(data, key, Map.get(data, to_string(key), default))
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
  defp maybe_option(options, key, value, true), do: Keyword.put(options, key, value)
  defp maybe_option(options, _key, _value, false), do: options

  defp start_discovery_harness(start_harness) do
    case start_harness.() do
      :ok -> :ok
      _result -> {:error, :harness_unavailable}
    end
  end
end
