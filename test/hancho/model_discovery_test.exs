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
          normalized_options: [:model, :approval_mode, :sandbox_mode],
          normalized_values: %{
            reasoning_effort: [nil, :low, :medium, :high, :xhigh]
          }
        },
        %AdapterSpec{
          provider: :claude,
          name: "Claude fixture",
          executable: "claude-fixture",
          normalized_options: [:model, :approval_mode, :sandbox_mode],
          normalized_values: %{reasoning_effort: [nil, :low, :medium, :high]}
        },
        %AdapterSpec{
          provider: :opencode,
          name: "OpenCode fixture",
          executable: "opencode-fixture",
          normalized_options: [:model, :approval_mode],
          normalized_values: %{reasoning_effort: [nil, :low, :medium, :high]}
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

    def run(provider, prompt, options) do
      send(self(), {:smoke, provider, prompt, options})
      model = options[:model]

      effective = if model == "gpt-fallback", do: "gpt-provider-default", else: model

      {:ok,
       RunResult.new!(%{
         run_id: "smoke-#{model}",
         provider: provider,
         status: :completed,
         text: "HANCHO_MODEL_OK",
         events: [
           Event.new!(provider: provider, type: :run_started, payload: %{"model" => effective})
         ]
       })}
    end
  end

  defmodule Command do
    def run("/fixture/codex", ["debug", "models"], _options) do
      result(fixture("codex.json"))
    end

    def run("/fixture/opencode", ["models"], _options) do
      result(fixture("opencode.txt"))
    end

    defp result(stdout) do
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

    defp fixture(name) do
      Path.expand("../fixtures/model_discovery/#{name}", __DIR__) |> File.read!()
    end
  end

  test "keeps CLI, configuration, smoke, effective-model, reasoning, and auth evidence separate" do
    project = project_with_workflow()

    assert {:ok, report} =
             Hancho.ModelDiscovery.discover(project,
               harness: Harness,
               command: Command,
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

    accepted = Enum.find(codex["smoke_tests"], &(&1["requested_model"] == "gpt-test"))
    fallback = Enum.find(codex["smoke_tests"], &(&1["requested_model"] == "gpt-fallback"))

    assert accepted["accepted"]
    assert accepted["effective_model"] == "gpt-test"
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

    models? = Keyword.get(options, :models, true)
    first_model = if models?, do: "    model: gpt-test\n", else: ""
    second_model = if models?, do: "    model: gpt-fallback\n", else: ""

    File.write!(
      Path.join(project.workflows_path, "models.yaml"),
      """
      name: models
      version: 1
      roles:
        primary:
          provider: codex
      #{first_model}    prompt: Primary role.
        fallback:
          provider: codex
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
