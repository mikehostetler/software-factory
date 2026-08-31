defmodule Hancho.MatrixRun do
  @moduledoc "Runs one task in isolated worktrees for selected Harness cells."

  alias Hancho.MatrixRun.{Cell, Comparison, Evidence, Report}

  @default_concurrency 1
  @default_timeout_ms 1_800_000
  @default_max_time_ms 3_600_000
  @default_max_tasks 20
  @reasoning_efforts ["low", "medium", "high", "xhigh"]
  @loopback_hosts ["localhost", "127.0.0.1", "::1"]
  @local_server_providers [:claude, :zai]

  @type option ::
          {:concurrency, pos_integer()}
          | {:git, module()}
          | {:harness, module()}
          | {:lease_api, module()}
          | {:local_server, String.t() | nil}
          | {:matrix_run_id, String.t()}
          | {:max_cost_usd, number() | nil}
          | {:max_tasks, pos_integer()}
          | {:max_time_ms, pos_integer()}
          | {:max_tokens, pos_integer() | nil}
          | {:reasoning_effort, String.t() | nil}
          | {:timeout_ms, pos_integer()}
          | {:worktree_setup, module()}

  @spec run(Hancho.Project.t(), String.t(), [String.t()], [option()]) ::
          {:ok, map()} | {:error, term()}
  def run(project, prompt, cell_specifications, options \\ []) do
    lease = Keyword.get(options, :lease_api, Hancho.FactoryLease)
    lease_options = Keyword.put_new(options, :lease_command, "matrix-run")

    lease.with_lease(project, lease_options, fn ->
      do_run(project, prompt, cell_specifications, options)
    end)
  end

  defp do_run(project, prompt, cell_specifications, options) do
    with {:ok, settings} <- settings(options),
         :ok <- validate_prompt(prompt),
         {:ok, cells} <- parse_cells(cell_specifications),
         :ok <- validate_cells(cells, settings),
         {:ok, local_server} <- validate_local_server(settings.local_server),
         :ok <- validate_models(cells),
         :ok <- validate_reasoning(cells, settings.reasoning_effort),
         :ok <- validate_local_server_cells(cells, local_server),
         {:ok, baseline} <- baseline(project, settings.git),
         {:ok, matrix_run_id} <- resolve_matrix_run_id(options),
         root = Path.join([project.hancho_dir, "matrix-runs", matrix_run_id]),
         :ok <- prepare_root(root),
         started_at = DateTime.utc_now(),
         started_monotonic = now(),
         {:ok, runs, stop_reason} <-
           execute(
             project,
             prompt,
             cells,
             baseline,
             matrix_run_id,
             root,
             local_server,
             settings,
             started_monotonic
           ) do
      finished_at = DateTime.utc_now()
      elapsed_ms = now() - started_monotonic
      comparison = Comparison.build(runs, local_server)

      report =
        %{
          "schema_version" => 1,
          "matrix_run_id" => matrix_run_id,
          "status" => matrix_status(runs, stop_reason),
          "task" => %{
            "prompt" => prompt,
            "sha256" => Evidence.digest(prompt),
            "source_task_count" => 1,
            "harness_task_count" => length(cells)
          },
          "baseline" => baseline,
          "timing" => %{
            "started_at" => DateTime.to_iso8601(started_at),
            "finished_at" => DateTime.to_iso8601(finished_at),
            "elapsed_ms" => elapsed_ms
          },
          "limits" => limits(settings, runs, elapsed_ms, stop_reason),
          "local_server" => local_server,
          "runs" => runs,
          "comparison" => comparison,
          "artifacts" => %{}
        }

      Report.persist(report, root)
    end
  rescue
    error -> {:error, {:matrix_run_exception, error, __STACKTRACE__}}
  catch
    kind, reason -> {:error, {:matrix_run_throw, kind, reason}}
  end

  defp settings(options) do
    settings = %{
      concurrency: Keyword.get(options, :concurrency, @default_concurrency),
      timeout_ms: Keyword.get(options, :timeout_ms, @default_timeout_ms),
      max_time_ms: Keyword.get(options, :max_time_ms, @default_max_time_ms),
      max_tasks: Keyword.get(options, :max_tasks, @default_max_tasks),
      max_tokens: Keyword.get(options, :max_tokens),
      max_cost_usd: Keyword.get(options, :max_cost_usd),
      reasoning_effort: Keyword.get(options, :reasoning_effort),
      local_server: Keyword.get(options, :local_server),
      git: Keyword.get(options, :git, Hancho.Git),
      harness: Keyword.get(options, :harness, Hancho.Harness),
      worktree_setup: Keyword.get(options, :worktree_setup, Hancho.WorktreeSetup)
    }

    cond do
      not positive_integer?(settings.concurrency) ->
        validation("Concurrency must be positive.")

      not positive_integer?(settings.timeout_ms) ->
        validation("The cell timeout must be positive.")

      not positive_integer?(settings.max_time_ms) ->
        validation("The matrix time limit must be positive.")

      not positive_integer?(settings.max_tasks) ->
        validation("The maximum task count must be positive.")

      not optional_positive_integer?(settings.max_tokens) ->
        validation("The token limit must be positive.")

      not optional_positive_number?(settings.max_cost_usd) ->
        validation("The cost limit must be positive.")

      settings.reasoning_effort not in [nil | @reasoning_efforts] ->
        validation("The reasoning effort is not valid.")

      true ->
        {:ok, settings}
    end
  end

  defp validate_prompt(prompt) when is_binary(prompt) do
    cond do
      not String.valid?(prompt) -> validation("The matrix task must be valid UTF-8 text.")
      String.trim(prompt) == "" -> validation("The matrix task must not be empty.")
      true -> :ok
    end
  end

  defp validate_prompt(_prompt), do: validation("The matrix task must be text.")

  defp parse_cells(specifications) do
    case Cell.parse_many(specifications) do
      {:ok, cells} -> {:ok, cells}
      {:error, reason} -> validation(reason)
    end
  end

  defp validate_cells([], _settings), do: validation("Select at least one matrix cell.")

  defp validate_cells(cells, settings) do
    cond do
      length(cells) > settings.max_tasks ->
        validation(
          "The matrix has #{length(cells)} Harness tasks. The maximum task count is #{settings.max_tasks}."
        )

      true ->
        :ok
    end
  end

  defp validate_models(cells) do
    case Enum.find(cells, &(&1.provider == :amp and is_binary(&1.requested_model))) do
      nil ->
        :ok

      cell ->
        validation(
          "The Amp Harness adapter does not support an explicit model for cell #{cell.id}."
        )
    end
  end

  defp validate_reasoning(cells, "xhigh") do
    if Enum.all?(cells, &(&1.provider in [:codex, :grok])) do
      :ok
    else
      validation("The xhigh reasoning effort is available only for Codex and Grok cells.")
    end
  end

  defp validate_reasoning(cells, reasoning) when is_binary(reasoning) do
    if Enum.any?(cells, &(&1.provider == :gemini)) do
      validation("The Gemini Harness adapter does not support a reasoning effort.")
    else
      :ok
    end
  end

  defp validate_reasoning(_cells, _reasoning), do: :ok

  defp validate_local_server_cells(_cells, nil), do: :ok

  defp validate_local_server_cells(cells, _local_server) do
    unsupported = Enum.reject(cells, &(&1.provider in @local_server_providers))

    case unsupported do
      [] ->
        :ok

      values ->
        providers = values |> Enum.map(& &1.provider_name) |> Enum.uniq() |> Enum.join(", ")

        validation(
          "Local-server mode requires an enforced loopback host allowlist. " <>
            "Unsupported providers: #{providers}. Use Claude or Z.AI cells."
        )
    end
  end

  defp validate_local_server(nil), do: {:ok, nil}

  defp validate_local_server(value) when is_binary(value) do
    uri = URI.parse(value)

    cond do
      uri.scheme not in ["http", "https"] ->
        validation("The local server must use HTTP or HTTPS.")

      uri.host not in @loopback_hosts ->
        validation("The local server host must be localhost, 127.0.0.1, or ::1.")

      uri.userinfo != nil or uri.query != nil or uri.fragment != nil ->
        validation(
          "The local server value must be an origin without credentials, a query, or a fragment."
        )

      uri.path not in [nil, "", "/"] ->
        validation("The local server value must not contain a path.")

      not is_nil(uri.port) and uri.port not in 1..65_535 ->
        validation("The local server port must be from 1 through 65535.")

      true ->
        {:ok, URI.to_string(%{uri | path: nil})}
    end
  end

  defp validate_local_server(_value), do: validation("The local server value must be text.")

  defp baseline(project, git) do
    with {:ok, status} <- git.status(working_dir: project.root, untracked_files: :all),
         :ok <- clean(status),
         {:ok, head} <- git.head(working_dir: project.root) do
      {:ok,
       %{
         "repository" => project.root,
         "branch" => status.branch,
         "head" => String.trim(head)
       }}
    end
  end

  defp clean(%Git.Status{entries: []}), do: :ok

  defp clean(%Git.Status{entries: entries}) do
    validation("The repository must be clean before a matrix run. Changes: #{inspect(entries)}")
  end

  defp prepare_root(root) do
    with :ok <- File.mkdir_p(Path.dirname(root)),
         :ok <- create_run_root(root),
         :ok <- File.mkdir(Path.join(root, "worktrees")),
         :ok <- File.mkdir_p(Path.join(root, "patches")),
         :ok <- File.mkdir_p(Path.join(root, "journals")),
         :ok <- File.chmod(root, 0o700) do
      :ok
    end
  end

  defp create_run_root(root) do
    case File.mkdir(root) do
      :ok -> :ok
      {:error, :eexist} -> validation("The matrix run directory already exists: #{root}.")
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute(
         project,
         prompt,
         cells,
         baseline,
         matrix_run_id,
         root,
         local_server,
         settings,
         started_at
       ) do
    execute_next(
      cells,
      [],
      project,
      prompt,
      baseline,
      matrix_run_id,
      root,
      local_server,
      settings,
      started_at
    )
  end

  defp execute_next(
         [],
         runs,
         _project,
         _prompt,
         _baseline,
         _matrix_run_id,
         _root,
         _local_server,
         settings,
         started_at
       ) do
    {:ok, runs, stop_reason(runs, settings, started_at)}
  end

  defp execute_next(
         cells,
         runs,
         project,
         prompt,
         baseline,
         matrix_run_id,
         root,
         local_server,
         settings,
         started_at
       ) do
    case stop_reason(runs, settings, started_at) do
      nil ->
        {chunk, rest} = Enum.split(cells, settings.concurrency)

        chunk_runs =
          run_chunk(
            chunk,
            project,
            prompt,
            baseline,
            matrix_run_id,
            root,
            local_server,
            settings,
            started_at
          )

        execute_next(
          rest,
          runs ++ chunk_runs,
          project,
          prompt,
          baseline,
          matrix_run_id,
          root,
          local_server,
          settings,
          started_at
        )

      reason ->
        skipped = Enum.map(cells, &skipped_run(&1, reason))
        {:ok, runs ++ skipped, reason}
    end
  end

  defp run_chunk(
         cells,
         project,
         prompt,
         baseline,
         matrix_run_id,
         root,
         local_server,
         settings,
         started_at
       ) do
    prepared = prepare_cells(cells, project, baseline, root, settings, started_at)

    not_runnable =
      for {:error, cell, reason, worktree} <- prepared do
        failed_setup_run(cell, worktree, reason)
      end ++
        for {:skipped, cell, reason} <- prepared do
          skipped_run(cell, reason)
        end

    runnable = for {:ok, prepared_cell} <- prepared, do: prepared_cell

    completed =
      runnable
      |> Task.async_stream(
        fn prepared_cell ->
          run_cell(
            prepared_cell,
            prompt,
            matrix_run_id,
            root,
            local_server,
            settings,
            started_at
          )
        end,
        max_concurrency: max(length(runnable), 1),
        ordered: true,
        timeout: :infinity
      )
      |> Enum.zip(runnable)
      |> Enum.map(fn
        {{:ok, run}, _prepared_cell} ->
          run

        {{:exit, reason}, prepared_cell} ->
          failed_worker_run(prepared_cell, reason, settings.git, root)
      end)

    (not_runnable ++ completed)
    |> Enum.sort_by(& &1["position"])
  end

  defp prepare_cells(cells, project, baseline, root, settings, started_at) do
    {prepared, _expired?} =
      Enum.map_reduce(cells, false, fn cell, expired? ->
        if expired? or now() - started_at >= settings.max_time_ms do
          {{:skipped, cell, "max_time_ms"}, true}
        else
          {prepare_cell(cell, project, baseline, root, settings), false}
        end
      end)

    prepared
  end

  defp prepare_cell(cell, project, baseline, root, settings) do
    worktree = Path.join([root, "worktrees", cell.id])

    case settings.git.create_worktree(project.root, worktree, baseline["head"]) do
      {:ok, :done} ->
        case settings.worktree_setup.prepare(worktree) do
          {:ok, mix_paths} ->
            {:ok,
             Map.merge(cell, %{
               worktree: worktree,
               mix_paths: mix_paths,
               baseline: baseline["head"]
             })}

          {:error, reason} ->
            {:error, cell, reason, worktree}
        end

      {:error, reason} ->
        {:error, cell, reason, worktree}
    end
  end

  defp run_cell(prepared, prompt, matrix_run_id, root, local_server, settings, started_at) do
    started_monotonic = now()
    remaining = settings.max_time_ms - (started_monotonic - started_at)

    if remaining <= 0 do
      skipped_prepared_run(prepared, "max_time_ms", root)
    else
      do_run_cell(
        prepared,
        prompt,
        matrix_run_id,
        root,
        local_server,
        settings,
        started_monotonic,
        remaining
      )
    end
  rescue
    error -> failed_worker_run(prepared, {:exception, error, __STACKTRACE__}, settings.git, root)
  catch
    kind, reason -> failed_worker_run(prepared, {kind, reason}, settings.git, root)
  end

  defp do_run_cell(
         prepared,
         prompt,
         matrix_run_id,
         root,
         local_server,
         settings,
         started_monotonic,
         remaining
       ) do
    started = DateTime.utc_now()
    timeout = min(settings.timeout_ms, remaining)
    {:ok, collector} = Agent.start_link(fn -> %{events: [], progress: []} end)

    event_callback = fn batch ->
      events = if is_list(batch), do: batch, else: [batch]

      Agent.update(collector, fn collected ->
        Map.update!(collected, :events, &Enum.reverse(events, &1))
      end)

      :ok
    end

    progress_callback = fn progress ->
      Agent.update(collector, &Map.update!(&1, :progress, fn values -> [progress | values] end))
      :ok
    end

    security = Hancho.ProviderSecurity.options(prepared.provider, local_hosts(local_server))

    options =
      harness_options(
        prepared,
        matrix_run_id,
        root,
        local_server,
        settings,
        timeout,
        event_callback,
        security
      )

    {result, collected} =
      try do
        result =
          call_harness(
            settings.harness,
            prepared.provider,
            safe_prompt(prompt, local_server),
            options,
            progress_callback
          )

        {result, Agent.get(collector, & &1)}
      after
        if Process.alive?(collector), do: Agent.stop(collector)
      end

    events = select_events(collected.events, result)
    workspace = workspace_evidence(prepared.worktree, prepared.id, settings.git, root)
    evidence = Evidence.from(events, workspace, local_server)
    terminal = terminal_result(result)
    usage = Evidence.observed_usage(prepared.provider, terminal, events)
    cost = Evidence.observed_cost(prepared.provider, usage, events)
    elapsed_ms = now() - started_monotonic

    %{
      "cell_id" => prepared.id,
      "position" => prepared.position,
      "provider" => prepared.provider_name,
      "requested_model" => prepared.requested_model,
      "requested_model_source" =>
        if(is_binary(prepared.requested_model),
          do: "configured",
          else: "provider_default_unpinned"
        ),
      "requested_model_matches_effective" =>
        requested_model_matches_effective(prepared.requested_model, evidence),
      "harness_run_id" => harness_run_id(terminal, collected, result),
      "provider_session_id" => provider_session_id(terminal, events),
      "status" => terminal_status(result),
      "output" => Evidence.output(terminal, events),
      "evidence" => evidence,
      "usage" => usage,
      "cost" => cost,
      "failure" => failure(result),
      "timing" => %{
        "started_at" => DateTime.to_iso8601(started),
        "finished_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "elapsed_ms" => elapsed_ms,
        "timeout_ms" => timeout
      },
      "isolation" => %{
        "mode" => "detached_git_worktree",
        "worktree" => prepared.worktree,
        "retained" => true,
        "baseline" => prepared.baseline,
        "journal_directory" => Path.join([root, "journals", prepared.provider_name])
      },
      "safety" => safety_evidence(security.evidence, local_server)
    }
  end

  defp harness_options(
         prepared,
         matrix_run_id,
         root,
         local_server,
         settings,
         timeout,
         event_callback,
         security
       ) do
    provider_options = security.provider_options

    [
      cwd: prepared.worktree,
      model: prepared.requested_model,
      env: prepared.mix_paths.env,
      approval_mode: approval_mode(prepared.provider),
      sandbox_mode: sandbox_mode(prepared.provider, local_server),
      reasoning_effort: reasoning_effort(settings.reasoning_effort),
      runtime_timeout_ms: timeout,
      idle_timeout_ms: timeout,
      await_timeout: timeout,
      cancellation_timeout_ms: 30_000,
      progress_interval_ms: min(30_000, timeout),
      event_callback: event_callback,
      event_poll_interval_ms: 100,
      journal_dir: Path.join([root, "journals", prepared.provider_name]),
      metadata: %{matrix_run_id: matrix_run_id, matrix_cell_id: prepared.id},
      provider_options: provider_options
    ]
  end

  defp call_harness(harness, provider, prompt, options, progress_callback) do
    cond do
      Code.ensure_loaded?(harness) and function_exported?(harness, :run_with_progress, 4) ->
        harness.run_with_progress(provider, prompt, options, progress_callback)

      Code.ensure_loaded?(harness) and function_exported?(harness, :run, 3) ->
        harness.run(provider, prompt, Keyword.drop(options, custom_harness_options()))

      true ->
        {:error, {:invalid_harness_api, harness}}
    end
  end

  defp custom_harness_options do
    [
      :cancellation_timeout_ms,
      :await_timeout,
      :event_callback,
      :event_poll_interval_ms,
      :journal_dir,
      :progress_interval_ms
    ]
  end

  defp select_events(captured, {:ok, %{events: result_events}}) do
    captured
    |> Enum.reverse()
    |> Kernel.++(result_events)
    |> unique_ordered_events()
  end

  defp select_events(captured, _result) do
    captured
    |> Enum.reverse()
    |> unique_ordered_events()
  end

  defp unique_ordered_events(events) do
    events
    |> Enum.with_index()
    |> Enum.uniq_by(fn {event, index} -> event_identity(event, index) end)
    |> Enum.sort_by(fn {event, index} -> {event_sequence(event), index} end)
    |> Enum.map(&elem(&1, 0))
  end

  defp event_identity(%{sequence: sequence}, _index) when is_integer(sequence) and sequence > 0,
    do: {:sequence, sequence}

  defp event_identity(%{"sequence" => sequence}, _index)
       when is_integer(sequence) and sequence > 0,
       do: {:sequence, sequence}

  defp event_identity(_event, index), do: {:position, index}

  defp event_sequence(%{sequence: sequence}) when is_integer(sequence), do: sequence
  defp event_sequence(%{"sequence" => sequence}) when is_integer(sequence), do: sequence
  defp event_sequence(_event), do: 0

  defp workspace_evidence(worktree, cell_id, git, root) do
    status = git.status(working_dir: worktree, untracked_files: :all)
    diff = git.diff(working_dir: worktree, ref: "HEAD")

    changes =
      case status do
        {:ok, value} ->
          value.entries
          |> Enum.map(&workspace_change(&1, worktree))
          |> Enum.sort_by(& &1["path"])

        {:error, _reason} ->
          []
      end

    patch =
      case diff do
        {:ok, %Git.Diff{raw: ""}} ->
          %{"status" => "not_observed", "path" => nil, "scope" => "tracked_changes_only"}

        {:ok, %Git.Diff{raw: raw}} ->
          path = Path.join([root, "patches", "#{cell_id}.patch"])
          redacted = Evidence.redact(raw)

          case File.write(path, redacted, [:binary, :sync]) do
            :ok ->
              case File.chmod(path, 0o600) do
                :ok ->
                  %{
                    "status" => "available",
                    "path" => path,
                    "scope" => "tracked_changes_only",
                    "bytes" => byte_size(redacted),
                    "source_bytes" => byte_size(raw),
                    "redacted" => redacted != raw,
                    "sha256" => Evidence.digest(raw)
                  }

                {:error, reason} ->
                  %{
                    "status" => "error",
                    "path" => path,
                    "scope" => "tracked_changes_only",
                    "error" => normalize(reason)
                  }
              end

            {:error, reason} ->
              %{
                "status" => "error",
                "path" => path,
                "scope" => "tracked_changes_only",
                "error" => normalize(reason)
              }
          end

        {:error, reason} ->
          %{
            "status" => "error",
            "path" => nil,
            "scope" => "tracked_changes_only",
            "error" => normalize(reason)
          }
      end

    %{
      "changes" => changes,
      "patch" => patch,
      "status_error" => case_error(status)
    }
  end

  defp workspace_change(entry, worktree) do
    change = %{
      "path" => entry.path,
      "index" => entry.index,
      "working_tree" => entry.working_tree
    }

    if untracked?(entry) do
      Map.put(change, "content", untracked_content(worktree, entry.path))
    else
      change
    end
  end

  defp untracked?(entry), do: entry.index == "?" and entry.working_tree == "?"

  defp untracked_content(worktree, relative_path) do
    root = Path.expand(worktree)
    path = Path.expand(relative_path, root)

    if path == root or not String.starts_with?(path, root <> "/") do
      %{"status" => "error", "reason" => "path_outside_worktree"}
    else
      case File.lstat(path) do
        {:ok, %File.Stat{type: :regular, size: size}} ->
          case file_digest(path) do
            {:ok, digest} ->
              %{"status" => "available", "type" => "regular", "bytes" => size, "sha256" => digest}

            {:error, reason} ->
              %{"status" => "error", "type" => "regular", "reason" => normalize(reason)}
          end

        {:ok, %File.Stat{type: :symlink}} ->
          case File.read_link(path) do
            {:ok, target} ->
              %{
                "status" => "available",
                "type" => "symlink",
                "sha256" => Evidence.digest(target)
              }

            {:error, reason} ->
              %{"status" => "error", "type" => "symlink", "reason" => normalize(reason)}
          end

        {:ok, %File.Stat{type: type}} ->
          %{"status" => "not_hashed", "type" => to_string(type)}

        {:error, reason} ->
          %{"status" => "error", "reason" => normalize(reason)}
      end
    end
  end

  defp file_digest(path) do
    with {:ok, device} <- File.open(path, [:read, :binary]) do
      try do
        digest_device(device, :crypto.hash_init(:sha256))
      after
        File.close(device)
      end
    end
  end

  defp digest_device(device, context) do
    case IO.binread(device, 64 * 1024) do
      :eof -> {:ok, context |> :crypto.hash_final() |> Base.encode16(case: :lower)}
      {:error, reason} -> {:error, reason}
      bytes -> digest_device(device, :crypto.hash_update(context, bytes))
    end
  end

  defp stop_reason(runs, settings, started_at) do
    cond do
      now() - started_at >= settings.max_time_ms -> "max_time_ms"
      limit_reached?(token_total(runs), settings.max_tokens) -> "max_tokens"
      limit_reached?(cost_total(runs), settings.max_cost_usd) -> "max_cost_usd"
      true -> nil
    end
  end

  defp token_total(runs) do
    Enum.reduce(runs, 0, fn run, total ->
      if get_in(run, ["usage", "additive"]) == true do
        total + measured_tokens(get_in(run, ["usage", "values"]))
      else
        total
      end
    end)
  end

  defp measured_tokens(values) when is_map(values) do
    case values["total_tokens"] do
      value when is_number(value) ->
        value

      _other ->
        input = values["input_tokens"]
        output = values["output_tokens"]

        if is_number(input) or is_number(output),
          do:
            if(is_number(input), do: input, else: 0) +
              if(is_number(output), do: output, else: 0),
          else: 0
    end
  end

  defp measured_tokens(_values), do: 0

  defp cost_total(runs) do
    Enum.reduce(runs, 0.0, fn run, total ->
      if get_in(run, ["cost", "additive"]) == true do
        total + (get_in(run, ["cost", "value_usd"]) || 0.0)
      else
        total
      end
    end)
  end

  defp limits(settings, runs, elapsed_ms, stop_reason) do
    %{
      "concurrency" => settings.concurrency,
      "timeout_ms_per_cell" => settings.timeout_ms,
      "max_time_ms" => settings.max_time_ms,
      "max_tasks" => settings.max_tasks,
      "max_tokens" => settings.max_tokens,
      "max_cost_usd" => settings.max_cost_usd,
      "observed_additive_tokens" => token_total(runs),
      "observed_additive_cost_usd" => cost_total(runs),
      "elapsed_ms" => elapsed_ms,
      "stop_reason" => stop_reason,
      "enforcement" => %{
        "usage_and_cost" =>
          "checked_between concurrent batches from provider-reported additive values",
        "possible_overshoot" =>
          "One active batch or one provider run can pass a measured cost or usage threshold.",
        "time" =>
          "Each cell gets the smaller remaining matrix time or cell timeout. Cancellation can add shutdown time.",
        "unavailable_values" => "not estimated and not added"
      }
    }
  end

  defp matrix_status(_runs, stop_reason) when is_binary(stop_reason), do: "limit_reached"

  defp matrix_status(runs, _stop_reason) do
    statuses = Enum.map(runs, & &1["status"])

    cond do
      Enum.all?(statuses, &(&1 == "completed")) -> "completed"
      Enum.any?(statuses, &(&1 == "completed")) -> "partial"
      true -> "failed"
    end
  end

  defp skipped_run(cell, reason) do
    base_run(cell, "skipped", %{"code" => "matrix_limit_reached", "limit" => reason})
  end

  defp skipped_prepared_run(prepared, reason, root) do
    prepared
    |> skipped_run(reason)
    |> put_in(["isolation"], %{
      "mode" => "detached_git_worktree",
      "worktree" => prepared.worktree,
      "retained" => true,
      "baseline" => prepared.baseline,
      "journal_directory" => Path.join([root, "journals", prepared.provider_name])
    })
  end

  defp failed_setup_run(cell, worktree, reason) do
    cell
    |> base_run("failed", %{"code" => "isolation_setup_failed", "reason" => normalize(reason)})
    |> put_in(["isolation"], %{
      "mode" => "detached_git_worktree",
      "worktree" => worktree,
      "retained" => File.dir?(worktree),
      "baseline" => nil,
      "journal_directory" => nil
    })
  end

  defp failed_worker_run(prepared, reason, git, root) do
    workspace = workspace_evidence(prepared.worktree, prepared.id, git, root)

    prepared
    |> base_run("failed", %{"code" => "matrix_worker_failed", "reason" => normalize(reason)})
    |> put_in(["evidence", "file_changes"], %{
      "status" =>
        cond do
          workspace["status_error"] != nil or get_in(workspace, ["patch", "status"]) == "error" ->
            "error"

          workspace["changes"] == [] ->
            "not_observed"

          true ->
            "observed"
        end,
      "workspace" => workspace["changes"],
      "harness_events" => [],
      "patch" => workspace["patch"],
      "status_error" => workspace["status_error"],
      "digest" =>
        Evidence.digest(%{
          "changes" => workspace["changes"],
          "status_error" => workspace["status_error"],
          "patch_status" => get_in(workspace, ["patch", "status"]),
          "patch_sha256" => get_in(workspace, ["patch", "sha256"])
        })
    })
    |> put_in(["isolation"], %{
      "mode" => "detached_git_worktree",
      "worktree" => prepared.worktree,
      "retained" => true,
      "baseline" => prepared.baseline,
      "journal_directory" => Path.join([root, "journals", prepared.provider_name])
    })
  end

  defp base_run(cell, status, failure) do
    %{
      "cell_id" => cell.id,
      "position" => cell.position,
      "provider" => cell.provider_name,
      "requested_model" => cell.requested_model,
      "requested_model_source" =>
        if(is_binary(cell.requested_model), do: "configured", else: "provider_default_unpinned"),
      "requested_model_matches_effective" => nil,
      "harness_run_id" => nil,
      "provider_session_id" => nil,
      "status" => status,
      "output" => %{"text" => "", "truncated" => false, "sha256" => Evidence.digest("")},
      "evidence" => empty_evidence(),
      "usage" =>
        Hancho.ProviderUsage.normalize(cell.provider, %{}) |> Hancho.ProviderUsage.to_map(),
      "cost" => %{
        "status" => "unavailable",
        "scope" => "unavailable",
        "additive" => false,
        "value_usd" => nil
      },
      "failure" => failure,
      "timing" => %{
        "started_at" => nil,
        "finished_at" => nil,
        "elapsed_ms" => 0,
        "timeout_ms" => nil
      },
      "isolation" => %{
        "mode" => "not_started",
        "worktree" => nil,
        "retained" => false,
        "baseline" => nil,
        "journal_directory" => nil
      },
      "safety" => %{
        "credential_protection" => nil,
        "commerce" => %{
          "mode" => "not_started",
          "network_allowlist_enforced" => false,
          "real_transactions" => "prohibited_by_task_policy"
        }
      }
    }
  end

  defp empty_evidence do
    %{
      "event_count" => 0,
      "effective_model" => %{"status" => "unavailable", "value" => nil, "source" => nil},
      "tool_activity" => %{
        "status" => "not_observed",
        "event_count" => 0,
        "retained_event_count" => 0,
        "truncated" => false,
        "events" => []
      },
      "file_changes" => %{
        "status" => "not_observed",
        "workspace" => [],
        "harness_events" => [],
        "patch" => nil,
        "status_error" => nil,
        "digest" => Evidence.digest([])
      },
      "tests" => %{"status" => "not_observed", "evidence" => []},
      "local_server" => %{
        "status" => "not_observed",
        "origin" => nil,
        "source" => "harness_tool_events",
        "server_log_verified" => false,
        "interaction_count" => 0,
        "truncated" => false,
        "interactions" => []
      }
    }
  end

  defp terminal_result({:ok, result}), do: result
  defp terminal_result(_result), do: nil
  defp terminal_status({:ok, %{status: status}}), do: Atom.to_string(status)

  defp terminal_status(
         {:error, {:harness_await_timeout, _run_id, _cancel, {:ok, %{status: :cancelled}}}}
       ),
       do: "cancelled"

  defp terminal_status({:error, _reason}), do: "failed"
  defp terminal_status(_result), do: "failed"

  defp failure({:ok, %{status: :completed}}), do: nil

  defp failure({:ok, %{error: error}}),
    do: normalize(error || "The Harness run did not complete.")

  defp failure({:error, reason}), do: normalize(reason)
  defp failure(result), do: normalize(result)

  defp harness_run_id(%{run_id: run_id}, _collected, _result) when is_binary(run_id), do: run_id

  defp harness_run_id(_terminal, collected, result) do
    Enum.find_value(collected.progress, fn progress ->
      Map.get(progress, :harness_run_id, Map.get(progress, "harness_run_id"))
    end) || error_run_id(result)
  end

  defp error_run_id({:error, %Jido.Harness.Error{run_id: run_id}}), do: run_id
  defp error_run_id({:error, {:harness_await_timeout, run_id, _cancel, _terminal}}), do: run_id
  defp error_run_id(_result), do: nil

  defp provider_session_id(%{provider_session_id: value}, _events) when is_binary(value),
    do: value

  defp provider_session_id(_terminal, events) do
    Enum.find_value(events, fn
      %Jido.Harness.Event{provider_session_id: value} when is_binary(value) ->
        value

      event when is_map(event) ->
        Map.get(event, :provider_session_id, Map.get(event, "provider_session_id"))

      _event ->
        nil
    end)
  end

  defp case_error({:ok, _value}), do: nil
  defp case_error({:error, reason}), do: normalize(reason)
  defp normalize(value), do: Hancho.Log.Event.normalize(value)

  defp safe_prompt(prompt, local_server) do
    local_rule =
      if is_binary(local_server) do
        "You may use only this local test server origin for commerce interactions: #{local_server}."
      else
        "Do not contact any commerce service."
      end

    """
    Hancho matrix safety rules:
    - Work only in the assigned isolated repository worktree.
    - Do not make a real purchase or create a real financial transaction.
    - Do not contact a production commerce service.
    - #{local_rule}

    Task:
    #{prompt}
    """
  end

  defp local_hosts(nil), do: []
  defp local_hosts(origin), do: [URI.parse(origin).host]

  defp approval_mode(provider) when provider in [:grok, :opencode, :pi], do: :auto_approve
  defp approval_mode(provider) when provider in [:amp, :kimi], do: :default
  defp approval_mode(_provider), do: :auto_edit

  defp sandbox_mode(provider, local_server)
       when provider in @local_server_providers and is_binary(local_server),
       do: :default

  defp sandbox_mode(provider, _local_server) when provider in [:amp, :kimi, :opencode, :pi],
    do: :default

  defp sandbox_mode(_provider, _local_server), do: :workspace_write

  defp reasoning_effort(nil), do: nil
  defp reasoning_effort(value), do: String.to_existing_atom(value)

  defp requested_model_matches_effective(nil, _evidence), do: nil

  defp requested_model_matches_effective(requested, evidence) do
    case get_in(evidence, ["effective_model", "value"]) do
      effective when is_binary(effective) -> requested == effective
      _value -> nil
    end
  end

  defp safety_evidence(credential_protection, nil) do
    %{
      "credential_protection" => normalize(credential_protection),
      "commerce" => %{
        "mode" => "no_local_server",
        "network_allowlist_enforced" => false,
        "real_transactions" => "prohibited_by_task_policy"
      }
    }
  end

  defp safety_evidence(credential_protection, local_server) do
    %{
      "credential_protection" => normalize(credential_protection),
      "commerce" => %{
        "mode" => "loopback_fixture",
        "origin" => local_server,
        "network_allowlist_enforced" => true,
        "real_transactions" => "prohibited_by_task_policy"
      }
    }
  end

  defp limit_reached?(_observed, nil), do: false
  defp limit_reached?(observed, limit), do: observed >= limit
  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp optional_positive_integer?(nil), do: true
  defp optional_positive_integer?(value), do: positive_integer?(value)
  defp optional_positive_number?(nil), do: true
  defp optional_positive_number?(value), do: is_number(value) and value > 0
  defp validation(message), do: {:error, {:validation, message}}

  defp resolve_matrix_run_id(options) do
    id = Keyword.get(options, :matrix_run_id) || matrix_run_id()

    if is_binary(id) and byte_size(id) <= 100 and
         Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]*\z/, id) do
      {:ok, id}
    else
      validation("The matrix run ID is not safe.")
    end
  end

  defp matrix_run_id do
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    random = :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
    "matrix-#{timestamp}-#{random}"
  end

  defp now, do: System.monotonic_time(:millisecond)
end
