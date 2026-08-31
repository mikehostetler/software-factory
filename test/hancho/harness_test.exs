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
           {200, :thinking_delta, "second"},
           {200, :output_text_final, "done"}
         ],
         fn {delay, type, text} ->
           Process.sleep(delay)
           Event.new!(provider: :codex, type: type, payload: %{"text" => text})
         end
       )}
    end
  end

  defmodule FailureAdapter do
    @behaviour Jido.Harness.Adapter

    alias Jido.Harness.Event

    @impl true
    def spec, do: SlowAdapter.spec()

    @impl true
    def status(config), do: SlowAdapter.status(config)

    @impl true
    def run(request, _context) do
      case request.prompt do
        "expired credentials" ->
          {:error, :expired_credentials}

        "cancelled" ->
          {:ok,
           [
             Event.new!(
               provider: :codex,
               type: :run_cancelled,
               payload: %{"stop_reason" => "cancelled"}
             )
           ]}

        "malformed stream" ->
          {:ok,
           [
             Event.new!(
               provider: :codex,
               type: :provider_event,
               payload: %{"kind" => "decode_error", "error" => "invalid JSON"}
             )
           ]}

        "partial tool call" ->
          {:ok,
           [
             Event.new!(
               provider: :codex,
               type: :tool_call,
               payload: %{"call_id" => "call-1", "name" => "write_file"}
             )
           ]}

        "retention gap" ->
          {:ok,
           Enum.map(1..10, fn sequence ->
             Event.new!(
               provider: :codex,
               type: :thinking_delta,
               payload: %{"text" => String.duplicate(Integer.to_string(sequence), 400)}
             )
           end)}
      end
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

    events = received_events()
    assert Enum.any?(events, &(&1.type == :run_completed))
    assert Enum.map(events, & &1.sequence) == Enum.to_list(1..length(events))

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
                 await_timeout: 300,
                 progress_interval_ms: 5,
                 andon_warning_ms: 50,
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
                       andon_warning_ms: 50,
                       inactivity_ms: inactivity_ms
                     }}

    assert inactivity_ms >= 50
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
                 await_timeout: 2_000,
                 runtime_timeout_ms: 2_000,
                 idle_timeout_ms: 2_000,
                 progress_interval_ms: 5,
                 andon_warning_ms: 50
               ],
               fn progress ->
                 send(test_pid, {:pulsed_progress, progress})
                 :ok
               end
             )

    assert result.status == :completed
    assert_received {:pulsed_progress, %{phase: :andon, andon_warning_ms: 50}}
    assert_received {:pulsed_progress, %{phase: :andon, andon_warning_ms: 50}}
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
                 await_timeout: 2_000,
                 runtime_timeout_ms: 2_000,
                 idle_timeout_ms: 2_000,
                 progress_interval_ms: 5,
                 andon_warning_ms: 1_000,
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

  test "reports provider failures and cancellation as their terminal phases" do
    install_adapter(FailureAdapter)
    test_pid = self()

    assert {:ok, failed} =
             run_failure_case("expired credentials", fn progress ->
               send(test_pid, {:failure_progress, progress})
               :ok
             end)

    assert failed.status == :failed

    assert_received {:failure_progress,
                     %{phase: :failed, terminal_status: :failed, harness_run_id: failed_id}}

    refute_received {:failure_progress, %{phase: :completed, harness_run_id: ^failed_id}}
    assert :ok = Jido.Harness.Run.prune(failed_id)

    assert {:ok, cancelled} =
             run_failure_case("cancelled", fn progress ->
               send(test_pid, {:cancel_progress, progress})
               :ok
             end)

    assert cancelled.status == :cancelled

    assert_received {:cancel_progress,
                     %{phase: :cancelled, terminal_status: :cancelled, harness_run_id: cancel_id}}

    refute_received {:cancel_progress, %{phase: :completed, harness_run_id: ^cancel_id}}
    assert :ok = Jido.Harness.Run.prune(cancel_id)
  end

  test "stops completed runs that contain malformed stream evidence" do
    install_adapter(FailureAdapter)
    test_pid = self()

    assert {:error,
            %{
              code: "harness_stream_invalid",
              harness_run_id: run_id,
              issues: [%{code: "malformed_provider_event", error: "invalid JSON"}]
            }} =
             run_failure_case("malformed stream", fn progress ->
               send(test_pid, {:malformed_progress, progress})
               :ok
             end)

    assert_received {:malformed_progress, %{phase: :stream_andon, harness_run_id: ^run_id}}

    assert {:ok, %{state: :completed}} = Jido.Harness.Run.info(run_id)
    assert :ok = Jido.Harness.Run.prune(run_id)
  end

  test "stops completed runs that contain an unfinished tool call" do
    install_adapter(FailureAdapter)
    test_pid = self()

    assert {:error,
            %{
              code: "harness_stream_invalid",
              harness_run_id: run_id,
              issues: [
                %{code: "incomplete_tool_calls", count: 1, call_ids: ["call-1"]}
              ]
            }} =
             run_failure_case("partial tool call", fn progress ->
               send(test_pid, {:partial_progress, progress})
               :ok
             end)

    assert_received {:partial_progress, %{phase: :stream_andon, harness_run_id: ^run_id}}
    assert :ok = Jido.Harness.Run.prune(run_id)
  end

  test "stops a completed run when journal retention removed stream evidence" do
    install_adapter(FailureAdapter)
    provider_config = Application.get_env(:jido_harness, :provider_config)
    config = provider_config |> then(&Map.new(&1 || %{})) |> Map.get(:codex, %{}) |> Map.new()

    Application.put_env(
      :jido_harness,
      :provider_config,
      Map.put(
        Map.new(provider_config || %{}),
        :codex,
        Map.put(config, :retention, %{segment_bytes: 200, disk_limit_bytes: 200})
      )
    )

    on_exit(fn -> restore_env(:provider_config, provider_config) end)

    assert {:error, %{code: "harness_stream_invalid", harness_run_id: run_id, issues: issues}} =
             run_failure_case("retention gap", fn _progress -> :ok end)

    assert Enum.any?(issues, &(&1.code == "event_replay_gap"))
    assert :ok = Jido.Harness.Run.prune(run_id)
  end

  defp temporary_directory do
    path = Path.join(System.tmp_dir!(), "hancho-harness-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp install_adapter(adapter) do
    providers = Application.get_env(:jido_harness, :providers)
    :ok = Hancho.Harness.ensure_started()

    Application.put_env(
      :jido_harness,
      :providers,
      Map.put(Map.new(providers || %{}), :codex, adapter)
    )

    on_exit(fn -> restore_env(:providers, providers) end)
  end

  defp run_failure_case(prompt, callback) do
    Hancho.Harness.run_with_progress(
      :codex,
      prompt,
      [
        cwd: temporary_directory(),
        await_timeout: 1_000,
        progress_interval_ms: 5,
        event_poll_interval_ms: 5
      ],
      callback
    )
  end

  defp config_values(argv) do
    argv
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn
      ["--config", value] -> [value]
      _pair -> []
    end)
  end

  defp received_events(batches \\ []) do
    receive do
      {:events, events} -> received_events([events | batches])
    after
      0 -> batches |> Enum.reverse() |> List.flatten()
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_harness, key)
  defp restore_env(key, value), do: Application.put_env(:jido_harness, key, value)
end
