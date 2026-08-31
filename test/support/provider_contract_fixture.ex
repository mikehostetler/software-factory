defmodule Hancho.ProviderContractFixture do
  @moduledoc false

  alias Jido.Harness.{AdapterSpec, Capabilities, Event, ProviderStatus}

  defmacro __using__(options) do
    provider = Keyword.fetch!(options, :provider)
    {capabilities, _bindings} = options |> Keyword.fetch!(:capabilities) |> Code.eval_quoted()
    native_cancel? = Map.fetch!(capabilities, :native_cancel?)

    quote do
      @behaviour Jido.Harness.Adapter
      @provider unquote(provider)
      @capabilities unquote(Macro.escape(capabilities))

      @impl true
      def spec do
        %AdapterSpec{
          provider: @provider,
          name: "Hancho #{@provider} contract fixture",
          executable: "hancho-#{@provider}-fixture",
          capabilities: Capabilities.new!(@capabilities),
          normalized_options: [],
          provider_options: []
        }
      end

      @impl true
      def status(config), do: Hancho.ProviderContractFixture.status(@provider, spec(), config)

      @impl true
      def run(request, context),
        do: Hancho.ProviderContractFixture.run(@provider, @capabilities, request, context)

      if unquote(native_cancel?) do
        @impl true
        def cancel(run_id, context),
          do: Hancho.ProviderContractFixture.cancel(@provider, run_id, context)
      end
    end
  end

  def status(provider, spec, config) do
    authenticated = Map.get(config, :authenticated, :unknown)

    status = %ProviderStatus{
      provider: provider,
      installed: true,
      compatible: true,
      authenticated: authenticated,
      capabilities: spec.capabilities,
      executable: spec.executable
    }

    {:ok, ProviderStatus.finalize(status)}
  end

  def run(provider, capabilities, request, context) do
    send_to_test(context, {:provider_contract_started, provider, context.run_id, request})

    case request.prompt do
      "block" ->
        receive do
          :finish_provider_contract_run -> {:ok, []}
        after
          30_000 -> {:ok, []}
        end

      "fail" ->
        {:error, {:fixture_provider_failure, provider}}

      _prompt ->
        {:ok, stream_events(provider, capabilities)}
    end
  end

  def cancel(provider, run_id, context) do
    send_to_test(context, {:provider_contract_cancelled, provider, run_id})
    :ok
  end

  defp stream_events(provider, capabilities) do
    [event(provider, :output_text_delta, %{"text" => "fixture output"})]
    |> maybe_prepend(capabilities.thinking?, fn ->
      [event(provider, :thinking_delta, %{"text" => "inspect"})]
    end)
    |> maybe_add(capabilities.tool_calls?, fn ->
      [
        event(provider, :tool_call, %{
          "call_id" => "fixture-call",
          "name" => "read_file",
          "input" => %{"path" => "fixture.txt"}
        }),
        event(provider, :tool_result, %{
          "call_id" => "fixture-call",
          "is_error" => false,
          "output" => "fixture result"
        })
      ]
    end)
    |> maybe_add(capabilities.usage?, fn ->
      [event(provider, :usage, %{"input_tokens" => 12, "output_tokens" => 5})]
    end)
    |> Kernel.++([event(provider, :output_text_final, %{"text" => "fixture complete"})])
  end

  defp event(provider, type, payload) do
    Event.new!(
      provider: provider,
      provider_session_id: "#{provider}-fixture-session",
      type: type,
      payload: payload
    )
  end

  defp maybe_add(events, true, events_fun), do: events ++ events_fun.()
  defp maybe_add(events, false, _events_fun), do: events
  defp maybe_prepend(events, true, events_fun), do: events_fun.() ++ events
  defp maybe_prepend(events, false, _events_fun), do: events

  defp send_to_test(context, message) do
    case get_in(context, [:config, :test_pid]) do
      pid when is_pid(pid) -> send(pid, message)
      _other -> :ok
    end
  end
end

defmodule Hancho.ProviderContractFixtures do
  @moduledoc false

  @contracts %{
    amp: %{
      streaming?: true,
      tool_calls?: true,
      tool_results?: true,
      thinking?: true,
      resume?: true,
      usage?: true,
      native_cancel?: true,
      file_changes?: false,
      structured_output?: false
    },
    claude: %{
      streaming?: true,
      tool_calls?: true,
      tool_results?: true,
      thinking?: true,
      resume?: true,
      usage?: true,
      native_cancel?: true,
      file_changes?: false,
      structured_output?: false
    },
    codex: %{
      streaming?: true,
      tool_calls?: true,
      tool_results?: true,
      thinking?: true,
      resume?: true,
      usage?: true,
      native_cancel?: true,
      file_changes?: true,
      structured_output?: true
    },
    gemini: %{
      streaming?: true,
      tool_calls?: true,
      tool_results?: true,
      thinking?: false,
      resume?: true,
      usage?: true,
      native_cancel?: true,
      file_changes?: false,
      structured_output?: false
    },
    grok: %{
      streaming?: true,
      tool_calls?: true,
      tool_results?: true,
      thinking?: true,
      resume?: true,
      usage?: true,
      native_cancel?: true,
      file_changes?: false,
      structured_output?: false
    },
    kimi: %{
      streaming?: true,
      tool_calls?: true,
      tool_results?: true,
      thinking?: false,
      resume?: true,
      usage?: false,
      native_cancel?: true,
      file_changes?: false,
      structured_output?: false
    },
    opencode: %{
      streaming?: true,
      tool_calls?: false,
      tool_results?: false,
      thinking?: false,
      resume?: false,
      usage?: false,
      native_cancel?: true,
      file_changes?: false,
      structured_output?: false
    },
    pi: %{
      streaming?: true,
      tool_calls?: true,
      tool_results?: true,
      thinking?: true,
      resume?: true,
      usage?: true,
      native_cancel?: true,
      file_changes?: false,
      structured_output?: false
    },
    zai: %{
      streaming?: true,
      tool_calls?: true,
      tool_results?: true,
      thinking?: true,
      resume?: true,
      usage?: true,
      native_cancel?: false,
      file_changes?: false,
      structured_output?: false
    }
  }

  for {provider, capabilities} <- @contracts do
    module = Module.concat(__MODULE__, provider |> Atom.to_string() |> Macro.camelize())

    contents =
      quote do
        use Hancho.ProviderContractFixture,
          provider: unquote(provider),
          capabilities: unquote(Macro.escape(capabilities))
      end

    Module.create(module, contents, Macro.Env.location(__ENV__))
  end

  @adapters Map.new(Map.keys(@contracts), fn provider ->
              {provider,
               Module.concat(__MODULE__, provider |> Atom.to_string() |> Macro.camelize())}
            end)

  def adapters, do: @adapters
  def capabilities, do: @contracts
end
