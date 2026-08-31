defmodule Hancho.ModelDiscoveryTest do
  use ExUnit.Case, async: false

  alias Jido.Harness.{AdapterSpec, Event, ProviderStatus, RunResult}

  defmodule Harness do
    def providers do
      [
        %AdapterSpec{
          provider: :codex,
          name: "Codex fixture",
          executable: "codex-fixture",
          normalized_options: [:model, :approval_mode, :sandbox_mode, :reasoning_effort],
          normalized_values: %{
            reasoning_effort: [nil, :low, :medium, :high, :xhigh]
          }
        },
        %AdapterSpec{
          provider: :claude,
          name: "Claude fixture",
          executable: "claude-fixture",
          normalized_options: [:model, :approval_mode, :sandbox_mode, :reasoning_effort],
          normalized_values: %{reasoning_effort: [nil, :low, :medium, :high]}
        },
        %AdapterSpec{
          provider: :opencode,
          name: "OpenCode fixture",
          executable: "opencode-fixture",
          normalized_options: [:model, :approval_mode, :reasoning_effort],
          normalized_values: %{reasoning_effort: [nil, :low, :medium, :high]}
        },
        %AdapterSpec{
          provider: :grok,
          name: "Grok fixture",
          executable: "grok-fixture",
          normalized_options: [
            :model,
            :allowed_tools,
            :approval_mode,
            :sandbox_mode,
            :disallowed_tools,
            :reasoning_effort
          ],
          normalized_values: %{reasoning_effort: [nil, :low, :medium, :high, :xhigh]}
        },
        %AdapterSpec{
          provider: :pi,
          name: "Pi fixture",
          executable: "pi-fixture",
          normalized_options: [
            :model,
            :allowed_tools,
            :disallowed_tools,
            :approval_mode,
            :sandbox_mode,
            :reasoning_effort
          ],
          normalized_values: %{
            approval_mode: [:default, :auto_approve],
            sandbox_mode: [:default, :read_only, :unrestricted],
            reasoning_effort: [nil, :low, :medium, :high]
          },
          provider_options: [
            :cli_path,
            :no_context_files,
            :no_extensions,
            :no_session,
            :no_skills,
            :project_trust
          ]
        }
      ]
    end

    def status(:codex) do
      {:ok,
       %ProviderStatus{
         provider: :codex,
         installed: true,
         compatible: true,
         authenticated: :unknown,
         smoke_ready: true,
         executable: "/fixture/codex",
         version: "codex fixture"
       }}
    end

    def status(:claude) do
      {:ok,
       %ProviderStatus{
         provider: :claude,
         installed: true,
         compatible: true,
         authenticated: :unknown,
         smoke_ready: true,
         executable: "/fixture/claude",
         version: "claude fixture"
       }}
    end

    def status(:opencode) do
      {:ok,
       %ProviderStatus{
         provider: :opencode,
         installed: true,
         compatible: true,
         authenticated: true,
         smoke_ready: true,
         executable: "/fixture/opencode",
         version: "opencode fixture"
       }}
    end

    def status(:grok) do
      {:ok,
       %ProviderStatus{
         provider: :grok,
         installed: true,
         compatible: true,
         authenticated: true,
         smoke_ready: true,
         executable: "/fixture/grok",
         version: "grok fixture"
       }}
    end

    def status(:pi) do
      {:ok,
       %ProviderStatus{
         provider: :pi,
         installed: true,
         compatible: true,
         authenticated: true,
         smoke_ready: true,
         executable: "/fixture/pi",
         version: "pi fixture"
       }}
    end

    def run(provider, prompt, options) do
      send(self(), {:smoke, provider, prompt, options})
      model = options[:model]

      effective = if model == "gpt-fallback", do: "gpt-provider-default", else: model

      events = [
        Event.new!(provider: provider, type: :run_started, payload: %{"model" => effective})
      ]

      events =
        if model == "gpt-tool" do
          events ++
            [
              Event.new!(
                provider: provider,
                type: :tool_call,
                payload: %{
                  "name" => "read",
                  "model" => "fixture-secret-must-not-appear"
                }
              )
            ]
        else
          events
        end

      {:ok,
       RunResult.new!(%{
         run_id: "smoke-#{model}",
         provider: provider,
         status: :completed,
         text: "HANCHO_MODEL_OK",
         events: events
       })}
    end
  end

  defmodule RecordingCommand do
    def run(executable, arguments, options) do
      send(self(), {:model_command, executable, arguments, options})
      stdout = Path.expand("../fixtures/model_discovery/codex.json", __DIR__) |> File.read!()

      {:ok,
       %Hancho.Command.Result{
         stdout: stdout,
         stderr: "",
         exit_status: 0,
         stdout_bytes: byte_size(stdout),
         stderr_bytes: 0,
         stdout_truncated: false,
         stderr_truncated: false
       }}
    end
  end

  defmodule UnauthenticatedGrokCommand do
    def run("/fixture/grok", ["models"], _options) do
      stderr = "not authenticated: fixture-secret-must-not-appear"

      {:ok,
       %Hancho.Command.Result{
         stdout: "",
         stderr: stderr,
         exit_status: 7,
         stdout_bytes: 0,
         stderr_bytes: byte_size(stderr),
         stdout_truncated: false,
         stderr_truncated: false
       }}
    end

    def run(executable, arguments, options),
      do: Hancho.ModelDiscoveryTest.Command.run(executable, arguments, options)
  end

  defmodule TruncatedCommand do
    def run("/fixture/codex", ["debug", "models"], _options) do
      {:ok,
       %Hancho.Command.Result{
         stdout: "trailing output",
         stderr: "",
         exit_status: 0,
         stdout_bytes: 5_000_000,
         stderr_bytes: 0,
         stdout_truncated: true,
         stderr_truncated: false
       }}
    end

    def run(executable, arguments, options),
      do: Hancho.ModelDiscoveryTest.Command.run(executable, arguments, options)
  end

  defmodule AuthenticatedGrokCommand do
    def run("/fixture/grok", ["models"], _options) do
      stdout =
        Hancho.ModelDiscoveryTest.Command.fixture("grok.txt")
        |> String.replace("You are not authenticated.", "You are logged in with grok.com.")

      Hancho.ModelDiscoveryTest.Command.result(stdout)
    end

    def run(executable, arguments, options),
      do: Hancho.ModelDiscoveryTest.Command.run(executable, arguments, options)
  end

  defmodule Command do
    def run("/fixture/codex", ["debug", "models"], _options) do
      result(fixture("codex.json"))
    end

    def run("/fixture/opencode", ["models"], _options) do
      result(fixture("opencode.txt"))
    end

    def run("/fixture/pi", ["--list-models"], _options) do
      result(fixture("pi.txt"))
    end

    def result(stdout) do
      {:ok,
       %Hancho.Command.Result{
         stdout: stdout,
         stderr: "fixture-secret-on-stderr",
         exit_status: 0,
         stdout_bytes: byte_size(stdout),
         stderr_bytes: 24,
         stdout_truncated: false,
         stderr_truncated: false
       }}
    end

    def fixture(name) do
      Path.expand("../fixtures/model_discovery/#{name}", __DIR__) |> File.read!()
    end
  end

  test "keeps CLI, configuration, smoke, effective-model, reasoning, and auth evidence separate" do
    project = project_with_workflow()

    assert {:ok, report} =
             Hancho.ModelDiscovery.discover(project,
               harness: Harness,
               command: Command,
               smoke: true,
               start_harness: fn -> :ok end
             )

    codex = Enum.find(report["providers"], &(&1["provider"] == "codex"))
    claude = Enum.find(report["providers"], &(&1["provider"] == "claude"))
    opencode = Enum.find(report["providers"], &(&1["provider"] == "opencode"))

    assert codex["authentication"] == "authenticated"
    assert codex["models"]["cli_reported"] == ["gpt-test"]
    assert codex["models"]["user_configured"] == ["gpt-fallback", "gpt-test"]
    assert codex["models"]["smoke_accepted"] == ["gpt-test"]
    assert codex["supported_reasoning_levels"] == ["low", "medium", "high", "xhigh"]

    assert Map.keys(report) |> Enum.sort() ==
             ["providers", "schema_version", "smoke_test_enabled", "source"]

    assert Map.keys(codex["cli"]) |> Enum.sort() ==
             ["compatible", "installed", "path", "version"]

    assert Map.keys(codex["model_discovery"]) |> Enum.sort() == ["detail", "status"]

    accepted = Enum.find(codex["smoke_tests"], &(&1["requested_model"] == "gpt-test"))
    fallback = Enum.find(codex["smoke_tests"], &(&1["requested_model"] == "gpt-fallback"))

    assert accepted["accepted"]
    assert accepted["effective_model"] == "gpt-test"

    assert Map.keys(accepted) |> Enum.sort() ==
             [
               "accepted",
               "detail",
               "effective_model",
               "effective_model_observed",
               "requested_model",
               "status",
               "tool_use_observed"
             ]

    refute fallback["accepted"]
    assert fallback["status"] == "fallback_observed"
    assert fallback["effective_model"] == "gpt-provider-default"

    assert claude["authentication"] == "unknown"
    assert claude["models"]["user_configured"] == []
    assert claude["models"]["smoke_accepted"] == []
    assert claude["smoke_tests"] == []

    assert opencode["models"]["user_configured"] == ["opencode/test"]
    assert opencode["models"]["smoke_accepted"] == []
    assert [%{"status" => "not_run", "detail" => detail}] = opencode["smoke_tests"]
    assert detail =~ "read-only"

    assert_receive {:smoke, :codex, prompt, options}
    assert prompt =~ "Do not use tools"
    assert options[:sandbox_mode] == :read_only
    assert options[:approval_mode] == :prompt
    assert options[:model] in ["gpt-test", "gpt-fallback"]
    assert options[:provider_options][:cli_path] == "/fixture/codex"
    assert options[:provider_options][:network_access_enabled] == false
    assert options[:provider_options][:skip_git_repo_check] == true
    refute File.exists?(options[:cwd])

    encoded = Jason.encode!(report)
    refute encoded =~ "fixture-secret"
    refute encoded =~ "gpt-hidden"
    refute encoded =~ "grok-default-only"
  end

  test "does not smoke a provider default or claim it as a configured model" do
    project = project_with_workflow(models: false)

    assert {:ok, report} =
             Hancho.ModelDiscovery.discover(project,
               harness: Harness,
               command: Command,
               start_harness: fn -> :ok end
             )

    codex = Enum.find(report["providers"], &(&1["provider"] == "codex"))
    assert codex["models"]["user_configured"] == []
    assert codex["models"]["smoke_accepted"] == []
    assert codex["smoke_tests"] == []
    refute_received {:smoke, _, _, _}
  end

  test "does not use provider quota unless smoke tests are explicitly enabled" do
    project = project_with_workflow(models: ["gpt-test"])

    assert {:ok, report} =
             Hancho.ModelDiscovery.discover(project,
               harness: Harness,
               command: Command,
               start_harness: fn -> :ok end
             )

    codex = Enum.find(report["providers"], &(&1["provider"] == "codex"))
    refute report["smoke_test_enabled"]
    assert [%{"status" => "not_run", "detail" => detail}] = codex["smoke_tests"]
    assert detail =~ "disabled"
    refute_received {:smoke, _, _, _}
  end

  test "keeps the JSON object shape stable for an unregistered provider" do
    project = project_with_workflow(provider: "unregistered", models: ["private-model"])

    assert {:ok, report} =
             Hancho.ModelDiscovery.discover(project,
               harness: Harness,
               command: Command,
               start_harness: fn -> :ok end
             )

    provider = Enum.find(report["providers"], &(&1["provider"] == "unregistered"))

    assert Map.keys(provider) |> Enum.sort() ==
             [
               "authentication",
               "cli",
               "configuration_sources",
               "configured_cli",
               "model_discovery",
               "models",
               "provider",
               "smoke_tests",
               "supported_reasoning_levels"
             ]

    assert provider["cli"] == %{
             "compatible" => nil,
             "installed" => false,
             "path" => nil,
             "version" => nil
           }

    assert Jason.decode!(Jason.encode!(report)) == report
  end

  test "parses deterministic provider fixtures and ignores secret fields" do
    cases = [
      {"amp", "amp.json", ["anthropic/claude-sonnet", "openai/gpt-codex"]},
      {"codex", "codex.json", ["gpt-test"]},
      {"grok", "grok.txt", ["grok-fast", "grok-test"]},
      {"kimi", "kimi.json", ["kimi-default", "kimi-k2-fast", "kimi-k2-test"]},
      {"opencode", "opencode.txt", ["anthropic/claude-test", "opencode/free-test"]},
      {"pi", "pi.txt", ["anthropic/claude-test", "openai/gpt-test"]}
    ]

    for {provider, name, expected} <- cases do
      output = fixture(name)
      assert {:ok, ^expected} = Hancho.ModelDiscovery.parse_models(provider, output)
      refute Enum.join(expected, " ") =~ "fixture-secret"
    end
  end

  test "rejects changed provider output instead of reporting an empty catalog" do
    for provider <- ["grok", "kimi", "opencode", "pi"] do
      assert {:error, :invalid_output} =
               Hancho.ModelDiscovery.parse_models(
                 provider,
                 "unrecognized fixture-secret-must-not-appear"
               )
    end

    assert {:ok, []} =
             Hancho.ModelDiscovery.parse_models(
               "pi",
               "No models available. Use /login to log into a provider via OAuth or API key."
             )
  end

  test "rejects an otherwise successful smoke result when the provider uses a tool" do
    project = project_with_workflow(models: ["gpt-tool"])

    assert {:ok, report} =
             Hancho.ModelDiscovery.discover(project,
               harness: Harness,
               command: Command,
               smoke: true,
               start_harness: fn -> :ok end
             )

    codex = Enum.find(report["providers"], &(&1["provider"] == "codex"))
    assert codex["models"]["smoke_accepted"] == []
    assert [%{"status" => "rejected", "tool_use_observed" => true}] = codex["smoke_tests"]
    refute Jason.encode!(report) =~ "fixture-secret"
  end

  test "disables Pi tools and local extensions during an explicit smoke test" do
    project = project_with_workflow(provider: "pi", models: ["anthropic/claude-test"])

    assert {:ok, _report} =
             Hancho.ModelDiscovery.discover(project,
               harness: Harness,
               command: Command,
               smoke: true,
               start_harness: fn -> :ok end
             )

    assert_receive {:smoke, :pi, _prompt, options}
    assert options[:allowed_tools] == []
    refute Keyword.has_key?(options, :disallowed_tools)
    assert options[:approval_mode] == :default
    assert options[:sandbox_mode] == :read_only

    assert options[:provider_options] == %{
             cli_path: "/fixture/pi",
             no_context_files: true,
             no_extensions: true,
             no_session: true,
             no_skills: true,
             project_trust: :deny
           }
  end

  test "uses Grok's empty tool allowlist during an explicit smoke test" do
    project = project_with_workflow(provider: "grok", models: ["grok-test"])

    assert {:ok, report} =
             Hancho.ModelDiscovery.discover(project,
               harness: Harness,
               command: AuthenticatedGrokCommand,
               smoke: true,
               start_harness: fn -> :ok end
             )

    grok = Enum.find(report["providers"], &(&1["provider"] == "grok"))
    assert grok["authentication"] == "authenticated"
    assert_receive {:smoke, :grok, _prompt, options}
    assert options[:allowed_tools] == []
    refute Keyword.has_key?(options, :disallowed_tools)
    assert is_list(options[:provider_options][:deny_rules])
  end

  test "uses one resolved custom CLI for the catalog command and smoke request" do
    project = project_with_workflow(models: ["gpt-test"], cli: :executable)
    executable = Path.join(project.root, "custom-codex")

    assert {:ok, report} =
             Hancho.ModelDiscovery.discover(project,
               harness: Harness,
               command: RecordingCommand,
               smoke: true,
               start_harness: fn -> :ok end
             )

    codex = Enum.find(report["providers"], &(&1["configured_cli"] == executable))
    assert codex["cli"]["installed"]
    assert codex["cli"]["path"] == executable
    assert_receive {:model_command, ^executable, ["debug", "models"], _options}
    assert_receive {:smoke, :codex, _prompt, options}
    assert options[:provider_options][:cli_path] == executable
  end

  test "does not report or smoke a custom path that is not executable" do
    project = project_with_workflow(models: ["gpt-test"], cli: :non_executable)

    assert {:ok, report} =
             Hancho.ModelDiscovery.discover(project,
               harness: Harness,
               command: RecordingCommand,
               smoke: true,
               start_harness: fn -> :ok end
             )

    executable = Path.join(project.root, "custom-codex")
    codex = Enum.find(report["providers"], &(&1["configured_cli"] == executable))
    refute codex["cli"]["installed"]
    assert codex["model_discovery"]["status"] == "failed"
    assert [%{"status" => "not_run", "detail" => detail}] = codex["smoke_tests"]
    assert detail =~ "not available"
    refute_received {:model_command, ^executable, _, _}
    refute_received {:smoke, _, _, _}
  end

  test "uses sanitized CLI output to correct authentication evidence" do
    project = project_with_workflow(provider: "grok", models: ["grok-test"])

    assert {:ok, report} =
             Hancho.ModelDiscovery.discover(project,
               harness: Harness,
               command: UnauthenticatedGrokCommand,
               smoke: true,
               start_harness: fn -> :ok end
             )

    grok = Enum.find(report["providers"], &(&1["provider"] == "grok"))
    assert grok["authentication"] == "unauthenticated"

    assert grok["model_discovery"]["detail"] ==
             "CLI model command exited with status 7."

    refute_received {:smoke, _, _, _}
    refute Jason.encode!(report) =~ "fixture-secret"
  end

  test "reports truncated model output without parsing its retained tail" do
    project = project_with_workflow(models: false)

    assert {:ok, report} =
             Hancho.ModelDiscovery.discover(project,
               harness: Harness,
               command: TruncatedCommand,
               start_harness: fn -> :ok end
             )

    codex = Enum.find(report["providers"], &(&1["provider"] == "codex"))

    assert codex["model_discovery"] == %{
             "detail" => "CLI model output exceeded the capture limit.",
             "status" => "failed"
           }
  end

  test "does not return a Harness startup error that can contain a secret" do
    project = project_with_workflow()

    result =
      Hancho.ModelDiscovery.discover(project,
        start_harness: fn -> {:error, "fixture-secret-must-not-appear"} end
      )

    assert result == {:error, :harness_unavailable}
    refute inspect(result) =~ "fixture-secret"
  end

  defp project_with_workflow(options \\ []) do
    root =
      Path.join(System.tmp_dir!(), "hancho-model-discovery-#{System.unique_integer([:positive])}")

    project = Hancho.Project.new(root)
    File.mkdir_p!(project.workflows_path)

    models =
      case Keyword.get(options, :models, ["gpt-test", "gpt-fallback"]) do
        true -> ["gpt-test", "gpt-fallback"]
        false -> []
        models -> models
      end

    first_model = if model = Enum.at(models, 0), do: "    model: #{model}\n", else: ""
    second_model = if model = Enum.at(models, 1), do: "    model: #{model}\n", else: ""
    provider = Keyword.get(options, :provider, "codex")

    cli =
      case Keyword.get(options, :cli) do
        mode when mode in [:executable, :non_executable] ->
          path = Path.join(root, "custom-codex")
          File.write!(path, "#!/bin/sh\nexit 0\n")
          if mode == :executable, do: File.chmod!(path, 0o700)
          "    cli: #{path}\n"

        nil ->
          ""
      end

    File.write!(
      Path.join(project.workflows_path, "models.yaml"),
      """
      name: models
      version: 1
      roles:
        primary:
          provider: #{provider}
      #{first_model}#{cli}    prompt: Primary role.
        fallback:
          provider: #{provider}
      #{second_model}    prompt: Fallback role.
        observer:
          provider: claude
          prompt: Observer role.
        unsafe_smoke:
          provider: opencode
          model: opencode/test
          prompt: Unsafe smoke role.
      steps:
        - name: implement
          role: primary
          action: Hancho.Actions.Implement
          params:
            prompt: Test.
      """
    )

    on_exit(fn -> File.rm_rf!(root) end)
    project
  end

  defp fixture(name),
    do: Path.expand("../fixtures/model_discovery/#{name}", __DIR__) |> File.read!()
end
