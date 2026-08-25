defmodule Hancho.HarnessTest do
  use ExUnit.Case, async: false

  alias Jido.Harness.{AdapterSpec, Capabilities, Event, ProviderStatus}

  defmodule SlowAdapter do
    @behaviour Jido.Harness.Adapter

    @impl true
    def spec do
      %AdapterSpec{
        provider: :codex,
        name: "Hancho slow test adapter",
        executable: "hancho-slow-test-adapter",
        capabilities: %Capabilities{},
        normalized_options: [],
        provider_options: []
      }
    end

    @impl true
    def status(_config) do
      {:ok,
       %ProviderStatus{
         provider: :codex,
         installed: true,
         compatible: true,
         authenticated: true,
         smoke_ready: true,
         capabilities: spec().capabilities,
         executable: spec().executable
       }}
    end

    @impl true
    def run(_request, context) do
      send(context.config.test_pid, {:slow_adapter_started, context.run_id})
      Process.sleep(30_000)
      {:ok, []}
    end

    @impl true
    def cancel(run_id, context) do
      send(context.config.test_pid, {:slow_adapter_cancelled, run_id})
      :ok
    end
  end

  defmodule PulsedAdapter do
    @behaviour Jido.Harness.Adapter

    alias Jido.Harness.Event

    @impl true
    def spec, do: SlowAdapter.spec()

    @impl true
    def status(config), do: SlowAdapter.status(config)

    @impl true
    def run(_request, _context) do
      {:ok,
       Stream.map(
         [
           {0, :thinking_delta, "first"},
           {30, :thinking_delta, "second"},
           {30, :output_text_final, "done"}
         ],
         fn {delay, type, text} ->
           Process.sleep(delay)
           Event.new!(provider: :codex, type: type, payload: %{"text" => text})
         end
       )}
    end
  end

  test "starts Jido.Harness through the shared command runtime" do
    assert Hancho.Harness.ensure_started() == :ok
    assert is_binary(Jido.Harness.version())
    assert Jido.Harness.providers() != []
  end

  test "passes Codex xhigh through the pinned Harness adapter" do
    :ok = Hancho.Harness.ensure_started()

    assert {:ok, request} =
             Jido.Harness.RequestResolver.resolve(:codex, %{
               prompt: "task",
               reasoning_effort: :xhigh
             })

    assert {:ok, argv} = Jido.Harness.Adapters.Codex.build_argv(request, %{})
    assert "model_reasoning_effort=\"xhigh\"" in config_values(argv)
  end

  test "reports detached run identity and normalized progress" do
    providers = Application.get_env(:jido_harness, :providers)
    provider_config = Application.get_env(:jido_harness, :provider_config)
    directory = temporary_directory()
    :ok = Hancho.Harness.ensure_started()

    Application.put_env(
      :jido_harness,
      :providers,
      Map.put(Map.new(providers || %{}), :codex, Hancho.TestHarnessAdapter)
    )

    on_exit(fn ->
      if providers do
        Application.put_env(:jido_harness, :providers, providers)
      else
        Application.delete_env(:jido_harness, :providers)
      end

      if provider_config do
        Application.put_env(:jido_harness, :provider_config, provider_config)
      else
        Application.delete_env(:jido_harness, :provider_config)
      end
    end)

    test_pid = self()

    assert {:ok, result} =
             Hancho.Harness.run_with_progress(
               :codex,
               "Implement Beadwork task hancho-integration",
               [
                 cwd: directory,
                 approval_mode: :auto_edit,
                 sandbox_mode: :workspace_write,
                 await_timeout: 1_000,
                 progress_interval_ms: 5,
                 event_poll_interval_ms: 5,
                 event_callback: fn events ->
                   send(test_pid, {:events, events})
                   :ok
                 end,
                 journal_dir: Path.join(directory, "journals")
               ],
               fn progress ->
                 send(test_pid, {:progress, progress})
                 :ok
               end
             )

    assert_received {:progress, %{phase: :started, harness_run_id: run_id}}

    assert_received {:progress,
                     %{
                       phase: :completed,
                       harness_run_id: ^run_id,
                       last_event: :run_completed
                     }}

    assert result.run_id == run_id
    assert result.status == :completed

    assert_received {:events, events}
    assert Enum.any?(events, &(&1.type == :run_completed))

    assert {:ok, info} = Jido.Harness.Run.info(run_id)
    assert String.starts_with?(info.journal_dir, Path.join(directory, "journals"))

    assert {:ok, attached} =
             Hancho.Harness.run_with_progress(
               :codex,
               "This prompt is not used for a retained completed run.",
               [
                 cwd: directory,
                 resume_run_id: run_id,
                 await_timeout: 1_000,
                 progress_interval_ms: 5
               ],
               fn progress ->
                 send(test_pid, {:reattach_progress, progress})
                 :ok
               end
             )

    assert attached.run_id == run_id
    assert_received {:reattach_progress, %{phase: :reattached, reattached: true}}
    assert :ok = Jido.Harness.Run.prune(run_id)
  end

  test "cancels a detached run when the Hancho wait boundary expires" do
    providers = Application.get_env(:jido_harness, :providers)
    provider_config = Application.get_env(:jido_harness, :provider_config)
    :ok = Hancho.Harness.ensure_started()

    Application.put_env(
      :jido_harness,
      :providers,
      Map.put(Map.new(providers || %{}), :codex, SlowAdapter)
    )

    Application.put_env(
      :jido_harness,
      :provider_config,
      Map.put(Map.new(provider_config || %{}), :codex, %{test_pid: self()})
    )

    on_exit(fn ->
      restore_env(:providers, providers)
      restore_env(:provider_config, provider_config)
    end)

    test_pid = self()

    assert {:error, {:harness_await_timeout, run_id, :ok, {:ok, %{status: :cancelled}}}} =
             Hancho.Harness.run_with_progress(
               :codex,
               "Wait until Hancho cancels this run.",
               [
                 cwd: temporary_directory(),
                 await_timeout: 50,
                 progress_interval_ms: 5,
                 andon_warning_ms: 10,
                 cancellation_timeout_ms: 1_000
               ],
               fn progress ->
                 send(test_pid, {:progress, progress})
                 :ok
               end
             )

    assert_received {:slow_adapter_started, ^run_id}

    assert_received {:progress,
                     %{
                       phase: :andon,
                       andon_warning_ms: 10,
                       inactivity_ms: inactivity_ms
                     }}

    assert inactivity_ms >= 10
    refute_received {:progress, %{phase: :andon}}
    assert_received {:slow_adapter_cancelled, ^run_id}
    assert {:ok, %{state: :cancelled}} = Jido.Harness.Run.info(run_id)
    assert :ok = Jido.Harness.Run.prune(run_id)
  end

  test "resets the Andon after provider activity returns" do
    providers = Application.get_env(:jido_harness, :providers)
    :ok = Hancho.Harness.ensure_started()

    Application.put_env(
      :jido_harness,
      :providers,
      Map.put(Map.new(providers || %{}), :codex, PulsedAdapter)
    )

    on_exit(fn -> restore_env(:providers, providers) end)
    test_pid = self()

    assert {:ok, result} =
             Hancho.Harness.run_with_progress(
               :codex,
               "Warn for two separate quiet periods.",
               [
                 cwd: temporary_directory(),
                 await_timeout: 1_000,
                 runtime_timeout_ms: 1_000,
                 idle_timeout_ms: 1_000,
                 progress_interval_ms: 5,
                 andon_warning_ms: 10
               ],
               fn progress ->
                 send(test_pid, {:pulsed_progress, progress})
                 :ok
               end
             )

    assert result.status == :completed
    assert_received {:pulsed_progress, %{phase: :andon, andon_warning_ms: 10}}
    assert_received {:pulsed_progress, %{phase: :andon, andon_warning_ms: 10}}
    refute_received {:pulsed_progress, %{phase: :andon}}
    assert :ok = Jido.Harness.Run.prune(result.run_id)
  end

  test "warns when provider activity has no productive progress" do
    providers = Application.get_env(:jido_harness, :providers)
    :ok = Hancho.Harness.ensure_started()

    Application.put_env(
      :jido_harness,
      :providers,
      Map.put(Map.new(providers || %{}), :codex, PulsedAdapter)
    )

    on_exit(fn -> restore_env(:providers, providers) end)
    test_pid = self()

    assert {:ok, result} =
             Hancho.Harness.run_with_progress(
               :codex,
               "Warn while thought events continue.",
               [
                 cwd: temporary_directory(),
                 await_timeout: 1_000,
                 runtime_timeout_ms: 1_000,
                 idle_timeout_ms: 1_000,
                 progress_interval_ms: 5,
                 andon_warning_ms: 200,
                 productive_warning_ms: 10
               ],
               fn progress ->
                 send(test_pid, {:productive_progress, progress})
                 :ok
               end
             )

    assert result.status == :completed

    assert_received {:productive_progress,
                     %{
                       phase: :productivity_andon,
                       productive_warning_ms: 10,
                       productive_event_count: 0,
                       last_productive_event: nil
                     }}

    refute_received {:productive_progress, %{phase: :andon}}
    assert :ok = Jido.Harness.Run.prune(result.run_id)
  end

  defp temporary_directory do
    path = Path.join(System.tmp_dir!(), "hancho-harness-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp config_values(argv) do
    argv
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn
      ["--config", value] -> [value]
      _pair -> []
    end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_harness, key)
  defp restore_env(key, value), do: Application.put_env(:jido_harness, key, value)
end
