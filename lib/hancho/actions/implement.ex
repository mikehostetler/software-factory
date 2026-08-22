defmodule Hancho.Actions.Implement do
  @moduledoc "Calls a CLI coding agent in the selected workspace."

  use Jido.Action,
    name: "hancho_implement",
    description: "Implements a Beadwork task with Jido.Harness",
    schema:
      Zoi.object(%{
        prompt: Zoi.string() |> Zoi.min(1),
        worktree_path: Zoi.string() |> Zoi.min(1),
        repo_path: Zoi.string() |> Zoi.min(1) |> Zoi.optional(),
        provider: Zoi.string() |> Zoi.min(1),
        cli: Zoi.string() |> Zoi.min(1) |> Zoi.optional(),
        model: Zoi.string() |> Zoi.min(1) |> Zoi.optional(),
        extra_args: Zoi.array(Zoi.string()) |> Zoi.default([]),
        reasoning_effort: Zoi.enum(["low", "medium", "high", "xhigh"]) |> Zoi.optional(),
        timeout_ms: Zoi.integer() |> Zoi.min(1),
        idle_timeout_ms: Zoi.integer() |> Zoi.min(1) |> Zoi.default(300_000),
        andon_warning_ms: Zoi.integer() |> Zoi.min(1) |> Zoi.default(120_000),
        productive_warning_ms: Zoi.integer() |> Zoi.min(1) |> Zoi.default(120_000),
        progress_interval_ms: Zoi.integer() |> Zoi.min(1) |> Zoi.default(30_000)
      })

  alias Hancho.Actions.Context
  alias Hancho.Harness.EventConsole

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

  @impl true
  def run(params, context) do
    harness = Context.service(context, :harness, Hancho.Harness)
    worktree_setup = Context.service(context, :worktree_setup, Hancho.WorktreeSetup)
    repository = Map.get(params, :repo_path) || repository_from_worktree(params.worktree_path)

    with {:ok, provider} <- fetch_provider(params.provider),
         :ok <- validate_reasoning(provider, Map.get(params, :reasoning_effort)),
         {:ok, mix_paths} <- worktree_setup.prepare(params.worktree_path),
         {:ok, prior_run} <- prior_harness_run(context),
         security = Hancho.ProviderSecurity.options(provider),
         :ok <- audit_configuration(context, params, mix_paths, security),
         provider_started_at = System.monotonic_time(:millisecond),
         {:ok, result} <-
           run_harness(
             harness,
             provider,
             params,
             repository,
             mix_paths,
             security,
             prior_run,
             context
           ),
         :ok <- completed(result),
         provider_elapsed_ms = System.monotonic_time(:millisecond) - provider_started_at do
      {:ok,
       %{
         provider: params.provider,
         model: Map.get(params, :model),
         model_source: model_source(params),
         harness_run_id: result.run_id,
         status: result.status,
         provider_elapsed_ms: provider_elapsed_ms,
         provider_elapsed_scope: "hancho_wait",
         usage:
           Hancho.ProviderUsage.normalize(provider, result.usage) |> Hancho.ProviderUsage.to_map(),
         text: tail(result.text, 20_000),
         text_truncated: result.text_truncated? or byte_size(result.text) > 20_000,
         mix_paths: Map.drop(mix_paths, [:env]),
         credential_protection: security.evidence
       }}
    end
  end

  @spec provider(String.t()) :: {:ok, atom()} | {:error, String.t()}
  def provider(name), do: fetch_provider(name)

  defp run_harness(
         harness,
         provider,
         params,
         repository,
         mix_paths,
         security,
         prior_run,
         context
       ) do
    reasoning_options = reasoning_options(provider, Map.get(params, :reasoning_effort))

    provider_options =
      security.provider_options
      |> Map.merge(provider_options(params, reasoning_options))

    options =
      [
        cwd: params.worktree_path,
        model: Map.get(params, :model),
        env: mix_paths.env,
        approval_mode: approval_mode(provider),
        sandbox_mode: :workspace_write,
        runtime_timeout_ms: params.timeout_ms,
        idle_timeout_ms: min(params.idle_timeout_ms, params.timeout_ms),
        andon_warning_ms: params.andon_warning_ms,
        productive_warning_ms: Map.get(params, :productive_warning_ms, 120_000),
        await_timeout: params.timeout_ms + 60_000,
        cancellation_timeout_ms: 30_000,
        progress_interval_ms: params.progress_interval_ms,
        journal_dir: Path.join([repository, ".hancho", "harness"]),
        resume_run_id: prior_run_id(prior_run),
        resume_cursor: prior_cursor(prior_run)
      ]
      |> Keyword.merge(Keyword.drop(reasoning_options, [:provider_options]))
      |> Keyword.put(:provider_options, provider_options)
      |> verbose_event_options(context)

    if Code.ensure_loaded?(harness) and function_exported?(harness, :run_with_progress, 4) do
      harness.run_with_progress(
        provider,
        params.prompt,
        options,
        progress_callback(context, params)
      )
    else
      harness.run(provider, params.prompt, Keyword.delete(options, :progress_interval_ms))
    end
  end

  # Grok's :auto_edit mode maps to acceptEdits, which can wait for interactive
  # approval of shell and web tools. Hancho runs Grok without an approval
  # responder, so use its non-interactive mode while the workspace sandbox
  # continues to limit filesystem access.
  defp approval_mode(:grok), do: :auto_approve
  defp approval_mode(_provider), do: :auto_edit

  # Jido Harness currently stops its provider-neutral enum at :high. Grok 1.0.5
  # accepts xhigh through its documented --reasoning-effort option.
  defp reasoning_options(:grok, "xhigh") do
    [reasoning_effort: nil, provider_options: %{extra_args: ["--reasoning-effort=xhigh"]}]
  end

  defp reasoning_options(_provider, nil), do: [reasoning_effort: nil]
  defp reasoning_options(_provider, "low"), do: [reasoning_effort: :low]
  defp reasoning_options(_provider, "medium"), do: [reasoning_effort: :medium]
  defp reasoning_options(_provider, "high"), do: [reasoning_effort: :high]

  defp validate_reasoning(:grok, "xhigh"), do: :ok

  defp validate_reasoning(_provider, "xhigh"),
    do: {:error, "The selected Harness provider does not support xhigh reasoning."}

  defp validate_reasoning(_provider, _effort), do: :ok

  defp provider_options(params, reasoning_options) do
    base =
      %{}
      |> maybe_put(:cli_path, Map.get(params, :cli))
      |> maybe_put(:extra_args, nonempty(Map.get(params, :extra_args)))

    Map.merge(base, Keyword.get(reasoning_options, :provider_options, %{}))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
  defp nonempty([]), do: nil
  defp nonempty(value), do: value

  defp progress_callback(context, params) do
    fn progress ->
      progress =
        Map.merge(progress, %{
          configured_model: Map.get(params, :model),
          model_source: model_source(params)
        })

      with :ok <- persist_harness_run(context, progress) do
        write_progress(context, progress)
        :ok
      end
    end
  end

  defp audit_configuration(context, params, mix_paths, security) do
    Hancho.Audit.write(Map.get(context, :log, :disabled), "Provider configuration",
      event: "implement.configuration",
      metadata: %{
        provider: params.provider,
        model: Map.get(params, :model),
        model_source: model_source(params),
        mix_paths: Map.drop(mix_paths, [:env]),
        credential_protection: security.evidence
      }
    )
  end

  defp model_source(params) do
    if is_binary(Map.get(params, :model)), do: "configured", else: "provider_default_unpinned"
  end

  defp write_progress(context, %{phase: :andon} = progress) do
    {label, event} = andon_activity(context)

    Hancho.Audit.write(
      context.log,
      "#{label} Andon: no provider activity for #{andon_duration(progress.inactivity_ms)}",
      event: event,
      level: :warning,
      metadata: progress
    )
  end

  defp write_progress(context, %{phase: :productivity_andon} = progress) do
    {label, event} = productivity_andon_activity(context)

    Hancho.Audit.write(
      context.log,
      "#{label} Andon: no productive progress for #{andon_duration(progress.productive_inactivity_ms)}",
      event: event,
      level: :warning,
      metadata: progress
    )
  end

  defp write_progress(context, progress) do
    {label, event} = activity(context)

    Hancho.Audit.write(context.log, "#{label} progress: #{progress.phase}",
      event: event,
      metadata: progress
    )
  end

  defp prior_harness_run(context) do
    case Map.get(context, :effect_store) do
      %{api: api, store: store, run_id: run_id, step_position: position} ->
        if function_exported?(api, :fetch_step_operation, 4) do
          case api.fetch_step_operation(store, run_id, position, operation_kind(context)) do
            {:ok, nil} ->
              {:ok, nil}

            {:ok, %{"id" => harness_run_id} = operation} ->
              {:ok,
               %{
                 id: harness_run_id,
                 cursor: get_in(operation, ["metadata", "last_sequence"]) || 0
               }}

            {:error, reason} ->
              {:error, {:harness_operation_unavailable, reason}}
          end
        else
          {:ok, nil}
        end

      _other ->
        {:ok, nil}
    end
  end

  defp persist_harness_run(context, %{harness_run_id: harness_run_id} = progress)
       when is_binary(harness_run_id) do
    case Map.get(context, :effect_store) do
      %{api: api, store: store, run_id: run_id, step_position: position} ->
        if function_exported?(api, :record_step_operation, 6) do
          api.record_step_operation(
            store,
            run_id,
            position,
            operation_kind(context),
            harness_run_id,
            Map.drop(progress, [:harness_run_id])
          )
        else
          :ok
        end

      _other ->
        :ok
    end
  end

  defp persist_harness_run(_context, _progress), do: :ok

  defp verbose_event_options(options, %{verbose: true}) do
    Keyword.merge(options,
      event_callback: &EventConsole.write/1,
      event_poll_interval_ms: 500
    )
  end

  defp verbose_event_options(options, _context), do: options

  defp activity(%{activity: :repair}), do: {"Repair", "repair.progress"}
  defp activity(_context), do: {"Implementation", "implement.progress"}

  defp andon_activity(%{activity: :repair}), do: {"Repair", "repair.andon"}
  defp andon_activity(_context), do: {"Implementation", "implement.andon"}

  defp productivity_andon_activity(%{activity: :repair}),
    do: {"Repair", "repair.productivity_andon"}

  defp productivity_andon_activity(_context),
    do: {"Implementation", "implement.productivity_andon"}

  defp andon_duration(milliseconds) when rem(milliseconds, 1_000) == 0,
    do: "#{div(milliseconds, 1_000)} seconds"

  defp andon_duration(milliseconds), do: "#{milliseconds} ms"

  defp operation_kind(%{activity: :repair}), do: "jido_harness.repair"
  defp operation_kind(_context), do: "jido_harness.run"

  defp prior_run_id(%{id: id}), do: id
  defp prior_run_id(_prior_run), do: nil
  defp prior_cursor(%{cursor: cursor}) when is_integer(cursor) and cursor >= 0, do: cursor
  defp prior_cursor(_prior_run), do: 0

  defp repository_from_worktree(path) do
    parts = path |> Path.expand() |> Path.split()

    case Enum.find_index(parts, &(&1 == ".hancho")) do
      nil -> Path.expand(path)
      index -> parts |> Enum.take(index) |> Path.join()
    end
  end

  defp fetch_provider(name) do
    case Map.fetch(@providers, name) do
      {:ok, provider} -> {:ok, provider}
      :error -> {:error, "Unknown Jido.Harness provider: #{name}"}
    end
  end

  defp completed(%{status: :completed}), do: :ok
  defp completed(result), do: {:error, result.error || "The coding agent did not complete."}

  defp tail(text, limit) when byte_size(text) <= limit, do: text
  defp tail(text, limit), do: binary_part(text, byte_size(text) - limit, limit)
end
