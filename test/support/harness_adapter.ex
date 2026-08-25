defmodule Hancho.TestHarnessAdapter do
  @moduledoc false

  @behaviour Jido.Harness.Adapter

  alias Jido.Harness.{AdapterSpec, Capabilities, Event, ProviderStatus}

  @impl true
  def spec do
    %AdapterSpec{
      provider: :codex,
      name: "Hancho deterministic test adapter",
      executable: "hancho-test-adapter",
      capabilities: %Capabilities{streaming?: true, file_changes?: true},
      normalized_options: [:approval_mode, :sandbox_mode, :reasoning_effort],
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
  def run(request, _context) do
    with :ok <- validate(request),
         path = Path.join(request.cwd, "implemented.txt"),
         :ok <- File.write(path, "implemented by the Jido.Harness test adapter\n") do
      {:ok,
       [
         event(:turn_started, %{"turn" => 1}),
         event(:file_change, %{"path" => path}),
         event(:output_text_final, %{"text" => "hancho-test-adapter-ok"}),
         event(:turn_completed, %{"turn" => 1})
       ]}
    end
  end

  defp validate(request) do
    cond do
      not String.contains?(request.prompt, "Implement Beadwork task hancho-integration") ->
        {:error, :unexpected_prompt}

      request.approval_mode != :auto_edit ->
        {:error, :unexpected_approval_mode}

      request.sandbox_mode != :workspace_write ->
        {:error, :unexpected_sandbox_mode}

      true ->
        :ok
    end
  end

  defp event(type, payload) do
    Event.new!(
      provider: :codex,
      provider_session_id: "hancho-test-session",
      type: type,
      payload: payload
    )
  end
end
