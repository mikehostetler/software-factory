defmodule Hancho.Harness do
  @moduledoc false

  @default_progress_interval_ms 30_000
  @default_andon_warning_ms 120_000
  @default_productive_warning_ms 120_000
  @default_event_poll_interval_ms 500
  @default_cancellation_timeout_ms 30_000

  def ensure_started do
    with :ok <- Hancho.Command.Runtime.ensure_started(),
         {:ok, _applications} <- Application.ensure_all_started(:jido_harness) do
      :ok
    end
  end

  def run(provider, prompt, options \\ []) do
    with :ok <- ensure_started() do
      Jido.Harness.run(provider, prompt, options)
    end
  end

  def status(provider) do
    with :ok <- ensure_started() do
      Jido.Harness.status(provider)
    end
  end

  def run_with_progress(provider, prompt, options, callback) when is_function(callback, 1) do
    await_timeout = Keyword.get(options, :await_timeout, :infinity)
    interval = Keyword.get(options, :progress_interval_ms, @default_progress_interval_ms)

    andon_warning_ms =
      Keyword.get(options, :andon_warning_ms, @default_andon_warning_ms)

    productive_warning_ms =
      Keyword.get(options, :productive_warning_ms, @default_productive_warning_ms)

    cancellation_timeout =
      Keyword.get(options, :cancellation_timeout_ms, @default_cancellation_timeout_ms)

    resume_run_id = Keyword.get(options, :resume_run_id)
    resume_cursor = Keyword.get(options, :resume_cursor, 0)
    journal_dir = Keyword.get(options, :journal_dir)
    event_callback = Keyword.get(options, :event_callback)

    event_poll_interval =
      Keyword.get(options, :event_poll_interval_ms, @default_event_poll_interval_ms)

    run_options =
      Keyword.drop(options, [
        :await_timeout,
        :progress_interval_ms,
        :andon_warning_ms,
        :productive_warning_ms,
        :cancellation_timeout_ms,
        :resume_run_id,
        :resume_cursor,
        :journal_dir,
        :event_callback,
        :event_poll_interval_ms
      ])

    with :ok <- configure_journal(provider, journal_dir),
         :ok <- ensure_started(),
         {:ok, run_id, phase} <- start_or_attach(provider, prompt, run_options, resume_run_id) do
      result =
        with :ok <- notify(callback, progress(run_id, provider, phase, 0, 0, nil)),
             {:ok, result} <-
               await(
                 run_id,
                 provider,
                 await_timeout,
                 interval,
                 resume_cursor,
                 callback,
                 event_callback,
                 event_poll_interval,
                 andon_warning_ms,
                 productive_warning_ms
               ) do
          {:ok, result}
        end

      case result do
        {:ok, _result} -> result
        {:error, :timeout} -> cancel_after_timeout(run_id, cancellation_timeout)
        {:error, _reason} = error -> cancel_after_error(run_id, cancellation_timeout, error)
      end
    end
  end

  defp start_or_attach(provider, prompt, options, nil) do
    start(provider, prompt, options)
  end

  defp start_or_attach(provider, prompt, options, run_id) do
    case Jido.Harness.Run.info(run_id) do
      {:ok, %{provider: ^provider, state: state}} when state in [:failed, :cancelled] ->
        start(provider, prompt, options)

      {:ok, %{provider: ^provider, state: state}}
      when state in [:starting, :running, :completed] ->
        {:ok, run_id, :reattached}

      {:ok, %{provider: other}} ->
        {:error, {:harness_provider_changed, run_id, other, provider}}

      {:error, :not_found} ->
        start(provider, prompt, options)

      {:error, reason} ->
        {:error, {:harness_run_unavailable, run_id, reason}}
    end
  end

  defp start(provider, prompt, options) do
    case Jido.Harness.Run.start(provider, prompt, options) do
      {:ok, run_id} -> {:ok, run_id, :started}
      {:error, reason} -> {:error, reason}
    end
  end

  defp await(
         run_id,
         provider,
         timeout,
         interval,
         cursor,
         callback,
         event_callback,
         event_poll_interval,
         andon_warning_ms,
         productive_warning_ms
       ) do
    started_at = System.monotonic_time(:millisecond)
    deadline = deadline(started_at, timeout)

    poll_interval =
      if is_function(event_callback, 1), do: min(event_poll_interval, interval), else: interval

    await_next(
      run_id,
      provider,
      started_at,
      deadline,
      interval,
      poll_interval,
      started_at + interval,
      cursor,
      nil,
      callback,
      event_callback,
      andon_warning_ms,
      started_at,
      false,
      productive_warning_ms,
      started_at,
      false,
      0,
      nil
    )
  end

  defp await_next(
         run_id,
         provider,
         started_at,
         deadline,
         progress_interval,
         poll_interval,
         next_progress_at,
         cursor,
         latest,
         callback,
         event_callback,
         andon_warning_ms,
         last_activity_at,
         andon_warned?,
         productive_warning_ms,
         last_productive_at,
         productive_warned?,
         productive_event_count,
         last_productive
       ) do
    wait = wait_time(deadline, poll_interval)

    case Jido.Harness.Run.await(run_id, wait) do
      {:ok, result} ->
        previous_latest = latest
        {next_cursor, latest, events} = replay(run_id, cursor, latest)
        now = now()

        {_last_activity_at, _andon_warned?, inactivity_periods, _activity_seen?} =
          activity_state(
            events,
            now,
            last_activity_at,
            andon_warned?,
            andon_warning_ms,
            previous_latest
          )

        {last_productive_at, productive_warned?, productive_event_count, last_productive} =
          productivity_state(
            events,
            now,
            last_productive_at,
            productive_warned?,
            productive_event_count,
            last_productive
          )

        productive_warn? =
          not productive_warned? and
            now - last_productive_at >= productive_warning_ms

        with :ok <- notify_events(event_callback, events),
             :ok <-
               notify_andon_warnings(
                 callback,
                 inactivity_periods,
                 run_id,
                 provider,
                 started_at,
                 next_cursor,
                 latest,
                 andon_warning_ms
               ),
             :ok <-
               maybe_notify_productivity_andon(
                 callback,
                 productive_warn?,
                 run_id,
                 provider,
                 started_at,
                 next_cursor,
                 latest,
                 now - last_productive_at,
                 productive_warning_ms,
                 productive_event_count,
                 last_productive
               ),
             :ok <-
               notify(
                 callback,
                 progress(run_id, provider, :completed, elapsed(started_at), next_cursor, latest)
               ) do
          {:ok, result}
        end

      {:error, :timeout} ->
        if expired?(deadline) do
          previous_latest = latest
          {next_cursor, latest, events} = replay(run_id, cursor, latest)
          now = now()

          {last_activity_at, andon_warned?, inactivity_periods, _activity_seen?} =
            activity_state(
              events,
              now,
              last_activity_at,
              andon_warned?,
              andon_warning_ms,
              previous_latest
            )

          {last_productive_at, productive_warned?, productive_event_count, last_productive} =
            productivity_state(
              events,
              now,
              last_productive_at,
              productive_warned?,
              productive_event_count,
              last_productive
            )

          warn? = not andon_warned? and now - last_activity_at >= andon_warning_ms

          inactivity_periods =
            if warn?, do: inactivity_periods ++ [now - last_activity_at], else: inactivity_periods

          productive_warn? =
            not productive_warned? and
              now - last_productive_at >= productive_warning_ms

          with :ok <- notify_events(event_callback, events),
               :ok <-
                 notify_andon_warnings(
                   callback,
                   inactivity_periods,
                   run_id,
                   provider,
                   started_at,
                   next_cursor,
                   latest,
                   andon_warning_ms
                 ),
               :ok <-
                 maybe_notify_productivity_andon(
                   callback,
                   productive_warn?,
                   run_id,
                   provider,
                   started_at,
                   next_cursor,
                   latest,
                   now - last_productive_at,
                   productive_warning_ms,
                   productive_event_count,
                   last_productive
                 ) do
            {:error, :timeout}
          end
        else
          previous_latest = latest
          {next_cursor, latest, events} = replay(run_id, cursor, latest)
          now = now()

          {last_activity_at, andon_warned?, inactivity_periods, activity_seen?} =
            activity_state(
              events,
              now,
              last_activity_at,
              andon_warned?,
              andon_warning_ms,
              previous_latest
            )

          {last_productive_at, productive_warned?, productive_event_count, last_productive} =
            productivity_state(
              events,
              now,
              last_productive_at,
              productive_warned?,
              productive_event_count,
              last_productive
            )

          warn? =
            activity_seen? and not andon_warned? and
              now - last_activity_at >= andon_warning_ms

          inactivity_periods =
            if warn?, do: inactivity_periods ++ [now - last_activity_at], else: inactivity_periods

          productive_warn? =
            not productive_warned? and
              now - last_productive_at >= productive_warning_ms

          with :ok <- notify_events(event_callback, events),
               :ok <-
                 notify_andon_warnings(
                   callback,
                   inactivity_periods,
                   run_id,
                   provider,
                   started_at,
                   next_cursor,
                   latest,
                   andon_warning_ms
                 ),
               :ok <-
                 maybe_notify_productivity_andon(
                   callback,
                   productive_warn?,
                   run_id,
                   provider,
                   started_at,
                   next_cursor,
                   latest,
                   now - last_productive_at,
                   productive_warning_ms,
                   productive_event_count,
                   last_productive
                 ),
               :ok <-
                 maybe_notify_progress(
                   callback,
                   now,
                   next_progress_at,
                   run_id,
                   provider,
                   started_at,
                   next_cursor,
                   latest
                 ) do
            await_next(
              run_id,
              provider,
              started_at,
              deadline,
              progress_interval,
              poll_interval,
              next_progress_at(now, next_progress_at, progress_interval),
              next_cursor,
              latest,
              callback,
              event_callback,
              andon_warning_ms,
              last_activity_at,
              andon_warned? or warn?,
              productive_warning_ms,
              last_productive_at,
              productive_warned? or productive_warn?,
              productive_event_count,
              last_productive
            )
          end
        end

      error ->
        error
    end
  end

  defp cancel_after_timeout(run_id, timeout) do
    cancel_result = Jido.Harness.Run.cancel(run_id)
    terminal = Jido.Harness.Run.await(run_id, timeout)
    {:error, {:harness_await_timeout, run_id, cancel_result, terminal}}
  end

  defp cancel_after_error(run_id, timeout, error) do
    case Jido.Harness.Run.info(run_id) do
      {:ok, info} ->
        if Jido.Harness.RunInfo.terminal?(info) do
          error
        else
          _result = Jido.Harness.Run.cancel(run_id)
          _terminal = Jido.Harness.Run.await(run_id, timeout)
          error
        end

      {:error, _reason} ->
        error
    end
  end

  defp configure_journal(_provider, nil), do: :ok

  defp configure_journal(provider, journal_dir) do
    with :ok <- File.mkdir_p(journal_dir),
         :ok <- File.chmod(journal_dir, 0o700) do
      :global.trans({__MODULE__, :journal_configuration}, fn ->
        provider_config = Application.get_env(:jido_harness, :provider_config, %{}) |> Map.new()
        config = provider_config |> Map.get(provider, %{}) |> Map.new()
        retention = config |> Map.get(:retention, %{}) |> Map.new()
        config = Map.put(config, :retention, Map.put(retention, :journal_dir, journal_dir))

        Application.put_env(
          :jido_harness,
          :provider_config,
          Map.put(provider_config, provider, config)
        )
      end)
    end
  end

  defp replay(run_id, cursor, latest) do
    case Jido.Harness.Run.replay(run_id, cursor: cursor, limit: 10_000) do
      {:ok, []} -> {cursor, latest, []}
      {:ok, events} -> {List.last(events).sequence, List.last(events), events}
      {:error, _reason} -> {cursor, latest, []}
    end
  end

  defp activity_state(
         events,
         now,
         last_activity_at,
         andon_warned?,
         andon_warning_ms,
         previous_latest
       ) do
    activity_seen? = activity_event?(previous_latest)

    previous_at =
      if activity_seen?, do: event_time(previous_latest, now), else: last_activity_at

    {_event_at, warning_sent?, inactivity_periods, activity_seen?} =
      Enum.reduce(
        events,
        {previous_at, andon_warned?, [], activity_seen?},
        fn event, {previous_at, warning_sent?, inactivity_periods, activity_seen?} ->
          event_at = event_time(event, now)
          inactivity_ms = max(event_at - previous_at, 0)

          inactivity_periods =
            if activity_seen? and activity_event?(event) and not warning_sent? and
                 inactivity_ms >= andon_warning_ms do
              inactivity_periods ++ [inactivity_ms]
            else
              inactivity_periods
            end

          {event_at, false, inactivity_periods, activity_seen? or activity_event?(event)}
        end
      )

    last_activity_at =
      if Enum.any?(events, &activity_event?/1), do: now, else: last_activity_at

    {last_activity_at, warning_sent?, inactivity_periods, activity_seen?}
  end

  defp activity_event?(%{type: type}),
    do: type not in [:run_started, :run_completed, :run_failed, :run_cancelled]

  defp activity_event?(_event), do: false

  defp productivity_state(
         events,
         now,
         last_productive_at,
         productive_warned?,
         productive_event_count,
         last_productive
       ) do
    productive = Enum.filter(events, &productive_event?/1)

    case List.last(productive) do
      nil ->
        {last_productive_at, productive_warned?, productive_event_count, last_productive}

      event ->
        {event_time(event, now), false, productive_event_count + length(productive), event.type}
    end
  end

  defp event_time(%{timestamp: timestamp}, now) when is_binary(timestamp) do
    with {:ok, datetime, _offset} <- DateTime.from_iso8601(timestamp) do
      age = max(System.system_time(:millisecond) - DateTime.to_unix(datetime, :millisecond), 0)
      now - age
    else
      _error -> now
    end
  end

  defp event_time(_event, now), do: now

  defp productive_event?(%{type: :file_change}), do: true

  defp productive_event?(%{type: :tool_result, payload: payload}) do
    not truthy?(payload["is_error"] || payload[:is_error]) and
      test_evidence?(payload["output"] || payload[:output])
  end

  defp productive_event?(_event), do: false

  defp test_evidence?(output) when is_binary(output) do
    Regex.match?(
      ~r/(\d+\s+tests?|\d+\s+passed|0 failures|test result|mix check|compil(?:e|ed))/i,
      output
    )
  end

  defp test_evidence?(_output), do: false
  defp truthy?(value), do: value in [true, "true", 1]

  defp notify_andon(
         callback,
         run_id,
         provider,
         started_at,
         cursor,
         latest,
         inactivity_ms,
         andon_warning_ms
       ) do
    details = %{
      inactivity_ms: inactivity_ms,
      andon_warning_ms: andon_warning_ms
    }

    callback
    |> notify(
      Map.merge(progress(run_id, provider, :andon, elapsed(started_at), cursor, latest), details)
    )
  end

  defp notify_andon_warnings(
         callback,
         inactivity_periods,
         run_id,
         provider,
         started_at,
         cursor,
         latest,
         andon_warning_ms
       ) do
    Enum.reduce_while(inactivity_periods, :ok, fn inactivity_ms, :ok ->
      case notify_andon(
             callback,
             run_id,
             provider,
             started_at,
             cursor,
             latest,
             inactivity_ms,
             andon_warning_ms
           ) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp maybe_notify_productivity_andon(
         _callback,
         false,
         _run_id,
         _provider,
         _started_at,
         _cursor,
         _latest,
         _inactivity_ms,
         _warning_ms,
         _event_count,
         _last_productive
       ),
       do: :ok

  defp maybe_notify_productivity_andon(
         callback,
         true,
         run_id,
         provider,
         started_at,
         cursor,
         latest,
         inactivity_ms,
         warning_ms,
         event_count,
         last_productive
       ) do
    details = %{
      productive_inactivity_ms: inactivity_ms,
      productive_warning_ms: warning_ms,
      productive_event_count: event_count,
      last_productive_event: last_productive
    }

    notify(
      callback,
      Map.merge(
        progress(run_id, provider, :productivity_andon, elapsed(started_at), cursor, latest),
        details
      )
    )
  end

  defp maybe_notify_progress(
         callback,
         now,
         next_progress_at,
         run_id,
         provider,
         started_at,
         cursor,
         latest
       ) do
    if now >= next_progress_at do
      notify(callback, progress(run_id, provider, :running, elapsed(started_at), cursor, latest))
    else
      :ok
    end
  end

  defp next_progress_at(now, next_progress_at, interval) when now >= next_progress_at,
    do: now + interval

  defp next_progress_at(_now, next_progress_at, _interval), do: next_progress_at

  defp progress(run_id, provider, phase, elapsed_ms, event_count, latest) do
    %{
      harness_run_id: run_id,
      provider: provider,
      phase: phase,
      reattached: phase == :reattached,
      elapsed_ms: elapsed_ms,
      event_count: event_count,
      last_event: if(latest, do: latest.type),
      last_sequence: if(latest, do: latest.sequence),
      provider_session_id: latest_provider_session_id(latest)
    }
  end

  defp latest_provider_session_id(nil), do: nil
  defp latest_provider_session_id(event), do: event.provider_session_id

  defp notify(callback, progress) do
    case callback.(progress) do
      :ok -> :ok
      {:error, reason} -> {:error, {:progress_callback_failed, reason}}
      other -> {:error, {:invalid_progress_callback_return, other}}
    end
  rescue
    error -> {:error, {:progress_callback_failed, {:exception, error}}}
  end

  defp notify_events(nil, _events), do: :ok

  defp notify_events(callback, events) when is_function(callback, 1) do
    case callback.(events) do
      :ok -> :ok
      {:error, reason} -> {:error, {:event_callback_failed, reason}}
      other -> {:error, {:invalid_event_callback_return, other}}
    end
  rescue
    error -> {:error, {:event_callback_failed, {:exception, error}}}
  end

  defp deadline(_started_at, :infinity), do: :infinity
  defp deadline(started_at, timeout), do: started_at + timeout

  defp wait_time(:infinity, interval), do: interval
  defp wait_time(deadline, interval), do: min(max(deadline - now(), 0), interval)
  defp expired?(:infinity), do: false
  defp expired?(deadline), do: now() >= deadline
  defp elapsed(started_at), do: now() - started_at
  defp now, do: System.monotonic_time(:millisecond)
end
