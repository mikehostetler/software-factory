defmodule Hancho.ProviderContractTest do
  use ExUnit.Case, async: false

  alias Hancho.Actions.Implement
  alias Jido.Harness.Error

  @providers [:amp, :claude, :codex, :gemini, :grok, :kimi, :opencode, :pi, :zai]
  @capabilities Hancho.ProviderContractFixtures.capabilities()

  @options %{
    amp: %{model?: false, reasoning: [:low, :medium, :high], extra_args?: false},
    claude: %{model?: true, reasoning: [:low, :medium, :high], extra_args?: false},
    codex: %{model?: true, reasoning: [:low, :medium, :high, :xhigh], extra_args?: false},
    gemini: %{model?: true, reasoning: [], extra_args?: false},
    grok: %{model?: true, reasoning: [:low, :medium, :high, :xhigh], extra_args?: true},
    kimi: %{model?: true, reasoning: [:low, :medium, :high], extra_args?: true},
    opencode: %{model?: true, reasoning: [:low, :medium, :high], extra_args?: true},
    pi: %{model?: true, reasoning: [:low, :medium, :high], extra_args?: true},
    zai: %{model?: true, reasoning: [:low, :medium, :high], extra_args?: false}
  }

  @usage_scopes %{
    amp: "run",
    claude: "run",
    codex: "run",
    gemini: "run",
    grok: "provider_cumulative",
    kimi: "unavailable",
    opencode: "unavailable",
    pi: "provider_reported_unknown",
    zai: "run"
  }

  defmodule WorktreeSetup do
    def prepare(_workspace) do
      {:ok,
       %{
         env: %{"MIX_DEPS_PATH" => "/fixture/deps", "MIX_BUILD_PATH" => "/fixture/build"},
         deps_path: "/fixture/deps",
         build_path: "/fixture/build"
       }}
    end
  end

  defmodule MustNotPrepareWorktree do
    def prepare(_workspace) do
      send(
        Application.fetch_env!(:hancho, :provider_contract_test_pid),
        :unexpected_worktree_prepare
      )

      {:error, :unexpected_worktree_prepare}
    end
  end

  defmodule RecordingHarness do
    def run_with_progress(provider, prompt, options, callback) do
      send(
        Application.fetch_env!(:hancho, :provider_contract_test_pid),
        {:recorded_provider_request, provider, prompt, options}
      )

      :ok =
        callback.(%{
          harness_run_id: "#{provider}-recorded-run",
          provider: provider,
          phase: :completed,
          elapsed_ms: 1,
          event_count: 1,
          last_event: :run_completed
        })

      capabilities = Map.fetch!(Hancho.ProviderContractFixtures.capabilities(), provider)
      usage = if capabilities.usage?, do: %{"input_tokens" => 12, "output_tokens" => 5}, else: %{}

      {:ok,
       Jido.Harness.RunResult.new!(%{
         run_id: "#{provider}-recorded-run",
         provider: provider,
         status: :completed,
         text: "recorded",
         usage: usage
       })}
    end
  end

  setup do
    test_pid = Application.get_env(:hancho, :provider_contract_test_pid)
    Application.put_env(:hancho, :provider_contract_test_pid, self())
    on_exit(fn -> restore_hancho_test_pid(test_pid) end)
    :ok
  end

  test "discovers exactly the CLI agents supported by Hancho" do
    assert :ok = Hancho.Harness.ensure_started()

    discovered = Jido.Harness.providers() |> Enum.map(& &1.provider) |> Enum.sort()
    assert discovered == Enum.sort(@providers)

    assert Hancho.ProviderContract.providers() ==
             Map.new(@providers, fn provider -> {Atom.to_string(provider), provider} end)

    for provider <- @providers do
      assert {:ok, provider} == Implement.provider(Atom.to_string(provider))
    end
  end

  for provider <- @providers do
    test "#{provider} adapter metadata matches the recorded contract" do
      provider = unquote(provider)
      expected_capabilities = capabilities(provider)
      expected_options = options(provider)

      assert {:ok, spec} = Jido.Harness.Registry.spec(provider)

      assert Map.take(Map.from_struct(spec.capabilities), Map.keys(expected_capabilities)) ==
               expected_capabilities

      assert :cli_path in spec.provider_options

      assert {:ok, request} =
               Jido.Harness.RequestResolver.resolve(provider, %{
                 prompt: "contract",
                 provider_options: %{cli_path: "/fixture/bin/#{provider}"}
               })

      assert request.provider_options.cli_path == "/fixture/bin/#{provider}"

      assert_resolution(provider, %{model: "fixture-model"}, expected_options.model?, :model)

      assert_resolution(
        provider,
        %{reasoning_effort: :low},
        :low in expected_options.reasoning,
        :reasoning_effort
      )

      assert_resolution(
        provider,
        %{reasoning_effort: :xhigh},
        :xhigh in expected_options.reasoning,
        :reasoning_effort
      )

      assert_resolution(
        provider,
        %{provider_options: %{extra_args: ["--fixture"]}},
        expected_options.extra_args?,
        :extra_args
      )
    end

    test "#{provider} implementation passes supported selections to Harness" do
      provider = unquote(provider)
      provider_name = Atom.to_string(provider)
      expected = options(provider)

      params =
        %{
          prompt: "provider contract",
          worktree_path: "/fixture/worktree",
          provider: provider_name,
          cli: "/fixture/bin/#{provider}",
          timeout_ms: 1_000
        }
        |> maybe_put(expected.model?, :model, "fixture-model")
        |> maybe_put(:low in expected.reasoning, :reasoning_effort, "low")
        |> maybe_put(expected.extra_args?, :extra_args, ["--fixture-extra"])

      assert {:ok, result} =
               Jido.Exec.run(Implement, params, %{
                 services: %{harness: RecordingHarness, worktree_setup: WorktreeSetup},
                 log: :disabled
               })

      assert_received {:recorded_provider_request, ^provider, "provider contract", options}
      assert options[:provider_options][:cli_path] == "/fixture/bin/#{provider}"
      assert options[:model] == if(expected.model?, do: "fixture-model")
      assert options[:reasoning_effort] == if(:low in expected.reasoning, do: :low)

      if expected.extra_args? do
        assert options[:provider_options][:extra_args] == ["--fixture-extra"]
      else
        refute Map.has_key?(options[:provider_options], :extra_args)
      end

      assert result.model == if(expected.model?, do: "fixture-model")
      assert result.usage["scope"] == usage_scope(provider)
    end
  end

  test "rejects provider-specific options before workspace setup" do
    assert {:error, "The amp Harness adapter does not support model selection."} =
             Hancho.ProviderContract.validate(:amp, %{model: "fixture-model"})

    assert {:error, "The gemini Harness adapter does not support reasoning effort."} =
             Hancho.ProviderContract.validate(:gemini, %{reasoning_effort: "high"})

    for provider <- [:amp, :claude, :codex, :gemini, :zai] do
      assert {:error, message} =
               Hancho.ProviderContract.validate(provider, %{extra_args: ["--fixture"]})

      assert message == "The #{provider} Harness adapter does not support extra arguments."
    end

    for provider <- [:amp, :opencode] do
      assert {:error, message} =
               Hancho.ProviderContract.validate(provider, %{sandbox_mode: "workspace_write"})

      assert message == "The #{provider} Harness adapter does not support sandbox mode."
    end

    assert {:error, "The kimi Harness adapter does not support sandbox mode workspace_write."} =
             Hancho.ProviderContract.validate(:kimi, %{sandbox_mode: "workspace_write"})

    assert {:error, "The pi Harness adapter does not support sandbox mode workspace_write."} =
             Hancho.ProviderContract.validate(:pi, %{sandbox_mode: "workspace_write"})

    assert {:error, error} =
             Jido.Exec.run(
               Implement,
               %{
                 prompt: "provider contract",
                 worktree_path: "/fixture/worktree",
                 provider: "amp",
                 model: "fixture-model",
                 timeout_ms: 1_000
               },
               %{services: %{worktree_setup: MustNotPrepareWorktree}, log: :disabled}
             )

    assert Exception.message(error) =~ "amp Harness adapter does not support model selection"
    refute_received :unexpected_worktree_prepare
  end

  test "uses a compatible approval mode for Gemini read-only runs" do
    assert {:ok, _result} =
             Jido.Exec.run(
               Implement,
               %{
                 prompt: "provider contract",
                 worktree_path: "/fixture/worktree",
                 provider: "gemini",
                 sandbox_mode: "read_only",
                 timeout_ms: 1_000
               },
               %{
                 services: %{harness: RecordingHarness, worktree_setup: WorktreeSetup},
                 log: :disabled
               }
             )

    assert_received {:recorded_provider_request, :gemini, "provider contract", options}
    assert options[:sandbox_mode] == :read_only
    assert options[:approval_mode] == :prompt
  end

  describe "deterministic provider lifecycle" do
    setup do
      providers = Application.get_env(:jido_harness, :providers)
      provider_config = Application.get_env(:jido_harness, :provider_config)
      assert :ok = Hancho.Harness.ensure_started()
      baseline_run_ids = Jido.Harness.Run.list() |> MapSet.new(& &1.run_id)

      Application.put_env(:jido_harness, :providers, Hancho.ProviderContractFixtures.adapters())

      Application.put_env(
        :jido_harness,
        :provider_config,
        Map.new(@providers, fn provider ->
          {provider, %{authenticated: false, test_pid: self()}}
        end)
      )

      on_exit(fn ->
        restore_env(:providers, providers)
        restore_env(:provider_config, provider_config)
        cleanup_runs(baseline_run_ids)
      end)

      :ok
    end

    for provider <- @providers do
      test "#{provider} normalizes authentication, streaming, tools, usage, errors, and resume" do
        provider = unquote(provider)
        capabilities = capabilities(provider)
        directory = temporary_directory()

        assert {:ok, status} = Jido.Harness.status(provider)
        assert status.authenticated == false
        assert status.smoke_ready == false

        test_pid = self()

        assert {:ok, result} =
                 Hancho.Harness.run_with_progress(
                   provider,
                   "stream",
                   [
                     cwd: directory,
                     await_timeout: 1_000,
                     runtime_timeout_ms: 1_000,
                     idle_timeout_ms: 1_000,
                     progress_interval_ms: 5,
                     event_poll_interval_ms: 5,
                     event_callback: fn events ->
                       send(test_pid, {:contract_events, provider, events})
                       :ok
                     end
                   ],
                   fn progress ->
                     send(test_pid, {:contract_progress, provider, progress})
                     :ok
                   end
                 )

        assert result.status == :completed
        assert result.provider == provider
        assert result.provider_session_id == "#{provider}-fixture-session"
        assert result.text == "fixture complete"
        assert ordered?(result.events)
        event_types = Enum.map(result.events, & &1.type)
        assert :output_text_delta in event_types
        assert :run_completed in event_types
        assert :tool_call in event_types == capabilities.tool_calls?
        assert :tool_result in event_types == capabilities.tool_results?
        assert :thinking_delta in event_types == capabilities.thinking?
        assert result.usage != %{} == capabilities.usage?
        assert_received {:contract_events, ^provider, events}
        assert Enum.all?(events, &(&1.provider == provider))

        assert {:ok, attached} =
                 Hancho.Harness.run_with_progress(
                   provider,
                   "this prompt is not run",
                   [cwd: directory, resume_run_id: result.run_id, await_timeout: 1_000],
                   fn progress ->
                     send(test_pid, {:resume_progress, provider, progress})
                     :ok
                   end
                 )

        assert attached.run_id == result.run_id
        assert_received {:resume_progress, ^provider, %{phase: :reattached, reattached: true}}
        assert :ok = Jido.Harness.Run.prune(result.run_id)

        assert {:ok, failed} =
                 Jido.Harness.run(provider, "fail", cwd: directory, await_timeout: 1_000)

        assert failed.status == :failed

        assert %Error{category: :execution, provider: ^provider, run_id: failed_run_id} =
                 failed.error

        assert failed_run_id == failed.run_id
        assert failed.error.cause == {:fixture_provider_failure, provider}
        assert :ok = Jido.Harness.Run.prune(failed.run_id)
      end

      test "#{provider} normalizes cancellation and runtime timeout" do
        provider = unquote(provider)
        capabilities = capabilities(provider)
        directory = temporary_directory()

        assert {:ok, cancelled_run_id} =
                 Jido.Harness.Run.start(provider, "block", cwd: directory)

        assert_receive {:provider_contract_started, ^provider, ^cancelled_run_id, _request}
        assert :ok = Jido.Harness.Run.cancel(cancelled_run_id)
        assert {:ok, cancelled} = Jido.Harness.Run.await(cancelled_run_id, 1_000)
        assert cancelled.status == :cancelled

        if capabilities.native_cancel? do
          assert_receive {:provider_contract_cancelled, ^provider, ^cancelled_run_id}
        else
          refute_receive {:provider_contract_cancelled, ^provider, ^cancelled_run_id}
        end

        assert :ok = Jido.Harness.Run.prune(cancelled_run_id)

        assert {:ok, timed_run_id} =
                 Jido.Harness.Run.start(provider, "block",
                   cwd: directory,
                   runtime_timeout_ms: 20,
                   idle_timeout_ms: 1_000
                 )

        assert_receive {:provider_contract_started, ^provider, ^timed_run_id, _request}
        assert {:ok, timed_out} = Jido.Harness.Run.await(timed_run_id, 1_000)
        assert timed_out.status == :failed

        assert %Error{category: :timeout, provider: ^provider, run_id: ^timed_run_id} =
                 timed_out.error

        if capabilities.native_cancel? do
          assert_receive {:provider_contract_cancelled, ^provider, ^timed_run_id}
        else
          refute_receive {:provider_contract_cancelled, ^provider, ^timed_run_id}
        end

        assert :ok = Jido.Harness.Run.prune(timed_run_id)
      end
    end
  end

  defp assert_resolution(provider, attributes, supported?, field) do
    attributes = Map.merge(%{prompt: "contract"}, attributes)

    if supported? do
      assert {:ok, _request} = Jido.Harness.RequestResolver.resolve(provider, attributes)
    else
      assert {:error, %Error{category: :validation} = error} =
               Jido.Harness.RequestResolver.resolve(provider, attributes)

      assert error.details[:field] == field or error.details[:key] == field
    end
  end

  defp maybe_put(map, true, key, value), do: Map.put(map, key, value)
  defp maybe_put(map, false, _key, _value), do: map

  defp capabilities(provider), do: Map.fetch!(@capabilities, provider)
  defp options(provider), do: Map.fetch!(@options, provider)
  defp usage_scope(provider), do: Map.fetch!(@usage_scopes, provider)

  defp ordered?(events) do
    Enum.map(events, & &1.sequence) == Enum.to_list(1..length(events))
  end

  defp temporary_directory do
    path =
      Path.join(
        System.tmp_dir!(),
        "hancho-provider-contract-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp cleanup_runs(baseline) do
    Jido.Harness.Run.list()
    |> Enum.reject(&MapSet.member?(baseline, &1.run_id))
    |> Enum.each(fn info ->
      unless Jido.Harness.RunInfo.terminal?(info), do: Jido.Harness.Run.cancel(info.run_id)
      _result = Jido.Harness.Run.prune(info.run_id)
    end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_harness, key)
  defp restore_env(key, value), do: Application.put_env(:jido_harness, key, value)

  defp restore_hancho_test_pid(nil),
    do: Application.delete_env(:hancho, :provider_contract_test_pid)

  defp restore_hancho_test_pid(pid),
    do: Application.put_env(:hancho, :provider_contract_test_pid, pid)
end
