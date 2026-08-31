defmodule Hancho.CLI do
  @moduledoc false

  @usage """
  Hancho manages a software factory for one Git repository.

  Usage:
    hancho init       Initialize Hancho in the current repository
    hancho doctor     Inspect the repository and local tools
    hancho models [--json] [--smoke]
                      Discover model evidence for configured CLI providers
    hancho run WORKFLOW ISSUE_ID [--verbose]
                      Run one Beadwork workflow in the foreground
    hancho run inspect RUN_ID
                      Inspect durable workflow and step state
    hancho retry RUN_ID [--verbose]
                      Continue one stopped workflow from its failed step
    hancho resume QUEUE_ID [--verbose]
                      Continue one stopped queue from its failed child
    hancho worktrees list
                      List retained Hancho worktrees and storage use
    hancho worktrees inspect RUN_ID
                      Inspect one retained worktree
    hancho worktrees clean RUN_ID
                      Remove generated artifacts from one retained worktree
    hancho attention list
                      List durable human decisions and questions
    hancho attention approve ID [--response TEXT]
    hancho attention reject ID [--response TEXT]
    hancho attention answer ID --response TEXT
                      Resolve one attention record
    hancho cockpit [--port N]
                      Start the local Hancho cockpit
    hancho demands list [--source all|github|beadwork]
                      Show outstanding GitHub and Beadwork demands
    hancho demands audit
                      Audit explicit GitHub and Beadwork mappings
    hancho demands sync --dry-run|--apply
                      Preview or apply missing demand mappings
    hancho queue WORKFLOW --source beadwork-ready --count N [--dry-run] [--verbose]
                      Run ready Beadwork tasks serially in the foreground
    hancho matrix-run --task-file PATH --cell PROVIDER[=MODEL] [--cell ...]
                      Run one task across isolated Harness provider and model cells
    hancho --version  Print the Hancho version
    hancho --help     Print this help
  """

  @switches [
    help: :boolean,
    version: :boolean,
    source: :string,
    count: :integer,
    verbose: :boolean,
    dry_run: :boolean,
    apply: :boolean,
    response: :string,
    port: :integer,
    json: :boolean,
    smoke: :boolean,
    task: :string,
    task_file: :string,
    cell: :keep,
    json: :boolean,
    concurrency: :integer,
    timeout_ms: :integer,
    max_time_ms: :integer,
    max_tasks: :integer,
    max_tokens: :integer,
    max_cost_usd: :float,
    local_server: :string,
    reasoning_effort: :string
  ]
  @aliases [h: :help, v: :version]

  def main(args) do
    case run(args) do
      0 -> :ok
      status -> System.stop(status)
    end
  end

  def run(args, options \\ []) do
    case OptionParser.parse(args, strict: @switches, aliases: @aliases) do
      {_parsed, _arguments, [invalid | _rest]} ->
        invalid_option(invalid)

      {parsed, arguments, []} ->
        dispatch(parsed, arguments, options)
    end
  end

  defp dispatch(parsed, arguments, options) do
    cond do
      parsed[:help] -> print_usage()
      parsed[:version] -> print_version()
      true -> dispatch_command(arguments, parsed, options)
    end
  end

  defp dispatch_command([], [], _options), do: print_usage()
  defp dispatch_command(["help"], [], _options), do: print_usage()
  defp dispatch_command(["version"], [], _options), do: print_version()

  defp dispatch_command(["doctor"], [], options) do
    report = Hancho.Doctor.run(options)
    IO.puts(Hancho.Doctor.format(report))

    if report.healthy?, do: 0, else: 1
  end

  defp dispatch_command(["init"], [], options) do
    case Hancho.Init.run(options) do
      {:ok, path} ->
        IO.puts("Initialized Hancho at #{path}")
        0

      {:error, message} ->
        IO.puts(:stderr, "ERROR: #{message}")
        1
    end
  end

  defp dispatch_command(arguments, parsed, options)
       when arguments in [["models"], ["models", "discover"]] do
    allowed = Keyword.drop(parsed, [:json, :smoke]) == []

    if allowed do
      with {:ok, project} <- discover_project(options),
           {:ok, report} <-
             models_api(options).discover(
               project,
               Keyword.put(options, :smoke, Keyword.get(parsed, :smoke, false))
             ) do
        if parsed[:json] do
          IO.puts(Jason.encode!(report, pretty: true))
        else
          IO.puts(models_api(options).format(report))
        end

        0
      else
        {:error, reason} -> command_error(reason)
      end
    else
      invalid_command_options(parsed)
    end
  end

  defp dispatch_command(["run", "inspect", run_id], [], options) do
    project_api = Keyword.get(options, :project_api, Hancho.Project)
    inspector = Keyword.get(options, :run_inspector, Hancho.Workflow.Inspector)
    cwd = Keyword.get(options, :cwd, File.cwd!())

    with {:ok, project} <- project_api.discover(cwd: cwd),
         {:ok, report} <- inspector.inspect(project, run_id, options) do
      print_run_report(report)
    else
      {:error, reason} ->
        IO.puts(:stderr, "ERROR: #{format_error(reason)}")
        1
    end
  end

  defp dispatch_command(["run", workflow, issue_id], parsed, options)
       when parsed == [] or parsed == [verbose: true] do
    project_api = Keyword.get(options, :project_api, Hancho.Project)
    runner = Keyword.get(options, :workflow_runner, Hancho.Workflow.Runner)
    cwd = Keyword.get(options, :cwd, File.cwd!())
    run_options = Keyword.put(options, :verbose, parsed[:verbose] || false)

    with {:ok, project} <- project_api.discover(cwd: cwd),
         {:ok, result} <-
           runner.run(
             project,
             workflow,
             %{"repo_path" => project.root, "issue_id" => issue_id},
             run_options
           ) do
      print_workflow_result(result)
    else
      {:error, reason} ->
        IO.puts(:stderr, "ERROR: #{format_error(reason)}")
        1
    end
  end

  defp dispatch_command(["retry", run_id], parsed, options)
       when parsed == [] or parsed == [verbose: true] do
    project_api = Keyword.get(options, :project_api, Hancho.Project)
    runner = Keyword.get(options, :workflow_runner, Hancho.Workflow.Runner)
    cwd = Keyword.get(options, :cwd, File.cwd!())
    retry_options = Keyword.put(options, :verbose, parsed[:verbose] || false)

    with {:ok, project} <- project_api.discover(cwd: cwd),
         {:ok, result} <- runner.retry(project, run_id, retry_options) do
      print_workflow_result(result)
    else
      {:error, reason} ->
        IO.puts(:stderr, "ERROR: #{format_error(reason)}")
        1
    end
  end

  defp dispatch_command(["resume", queue_id], parsed, options)
       when parsed == [] or parsed == [verbose: true] do
    project_api = Keyword.get(options, :project_api, Hancho.Project)
    runner = Keyword.get(options, :queue_runner, Hancho.Workflow.QueueRunner)
    cwd = Keyword.get(options, :cwd, File.cwd!())

    resume_options =
      options
      |> Keyword.put(:verbose, parsed[:verbose] || false)
      |> Keyword.put(:progress, fn message ->
        IO.puts(message)
        :ok
      end)

    with {:ok, project} <- project_api.discover(cwd: cwd),
         {:ok, result} <- runner.resume(project, queue_id, resume_options) do
      print_queue_result(result)
    else
      {:error, reason} ->
        IO.puts(:stderr, "ERROR: #{format_error(reason)}")
        1
    end
  end

  defp dispatch_command(["worktrees", "list"], [], options) do
    with {:ok, project} <- discover_project(options),
         {:ok, reports} <- worktrees_api(options).list(project, options) do
      print_worktree_list(reports)
    else
      {:error, reason} -> command_error(reason)
    end
  end

  defp dispatch_command(["worktrees", "inspect", id], [], options) do
    with {:ok, project} <- discover_project(options),
         {:ok, report} <- worktrees_api(options).inspect(project, id, options) do
      print_worktree(report)
    else
      {:error, reason} -> command_error(reason)
    end
  end

  defp dispatch_command(["worktrees", "clean", id], [], options) do
    with {:ok, project} <- discover_project(options),
         {:ok, result} <- worktrees_api(options).clean(project, id, options) do
      removed = if result.removed == [], do: "none", else: Enum.join(result.removed, ", ")
      IO.puts("Cleaned #{result.id}: #{removed}")
      IO.puts("Reclaimed: #{result.reclaimed_bytes} bytes")
      IO.puts("Source changes retained: yes")
      0
    else
      {:error, reason} -> command_error(reason)
    end
  end

  defp dispatch_command(["attention", "list"], [], options) do
    with {:ok, project} <- discover_project(options),
         {:ok, store} <- Hancho.Workflow.Store.open(project.bedrock_path),
         {:ok, records} <- Hancho.Workflow.Store.list_attention(store) do
      Enum.each(records, fn record ->
        IO.puts("#{record["id"]}: #{record["kind"]} #{record["status"]} — #{record["title"]}")
      end)

      0
    else
      {:error, reason} -> command_error(reason)
    end
  end

  defp dispatch_command(["attention", action, id], parsed, options)
       when action in ["approve", "reject", "answer"] do
    response = parsed[:response]

    if action == "answer" and not is_binary(response) do
      IO.puts(:stderr, "ERROR: attention answer requires --response.")
      2
    else
      status = %{"approve" => "approved", "reject" => "rejected", "answer" => "answered"}[action]

      with {:ok, project} <- discover_project(options),
           {:ok, store} <- Hancho.Workflow.Store.open(project.bedrock_path),
           {:ok, record} <- Hancho.Workflow.Store.resolve_attention(store, id, status, response),
           :ok <- Hancho.Workflow.Store.flush(store) do
        IO.puts("Attention #{record["id"]}: #{record["status"]}")
        0
      else
        {:error, reason} -> command_error(reason)
      end
    end
  end

  defp dispatch_command(["cockpit"], parsed, options) do
    port = parsed[:port] || 0

    if port in 0..65_535 do
      case discover_project(options) do
        {:ok, project} -> Hancho.Cockpit.serve(project, port, options)
        {:error, reason} -> command_error(reason)
      end
    else
      IO.puts(:stderr, "ERROR: cockpit port must be from 0 through 65535.")
      2
    end
  end

  defp dispatch_command(["demands", "list"], parsed, options) do
    allowed = Keyword.drop(parsed, [:source]) == []

    if allowed do
      source = parsed[:source] || "all"

      with {:ok, project} <- discover_project(options),
           {:ok, result} <- demands_api(options).list(project, source, demand_options(options)) do
        print_demands(result)
      else
        {:error, reason} -> command_error(reason)
      end
    else
      invalid_command_options(parsed)
    end
  end

  defp dispatch_command(["demands", "audit"], [], options) do
    with {:ok, project} <- discover_project(options),
         {:ok, result} <- demands_api(options).audit(project, demand_options(options)) do
      print_demand_audit(result)
    else
      {:error, reason} -> command_error(reason)
    end
  end

  defp dispatch_command(["demands", "sync"], parsed, options) do
    mode =
      case {parsed[:dry_run] || false, parsed[:apply] || false, length(parsed)} do
        {true, false, 1} -> :dry_run
        {false, true, 1} -> :apply
        _ -> nil
      end

    if mode do
      with {:ok, project} <- discover_project(options),
           {:ok, result} <- demands_api(options).sync(project, mode, demand_options(options)) do
        print_demand_sync(result)
      else
        {:error, reason} -> command_error(reason)
      end
    else
      IO.puts(:stderr, "ERROR: demands sync requires exactly one of --dry-run or --apply.")
      2
    end
  end

  defp dispatch_command(["queue", workflow], parsed, options) do
    source = parsed[:source]
    count = parsed[:count]

    if is_binary(source) and is_integer(count) and count > 0 do
      project_api = Keyword.get(options, :project_api, Hancho.Project)
      runner = Keyword.get(options, :queue_runner, Hancho.Workflow.QueueRunner)
      cwd = Keyword.get(options, :cwd, File.cwd!())

      queue_options =
        options
        |> Keyword.put(:verbose, parsed[:verbose] || false)
        |> Keyword.put(:progress, fn message ->
          IO.puts(message)
          :ok
        end)

      with {:ok, project} <- project_api.discover(cwd: cwd),
           {:ok, result} <-
             run_or_preview(runner, project, workflow, source, count, parsed, queue_options) do
        print_queue_output(result, parsed[:dry_run] || false)
      else
        {:error, reason} ->
          IO.puts(:stderr, "ERROR: #{format_error(reason)}")
          1
      end
    else
      IO.puts(:stderr, "ERROR: queue requires --source and a positive --count.")
      2
    end
  end

  defp dispatch_command(["matrix-run"], parsed, options) do
    allowed = [
      :task,
      :task_file,
      :cell,
      :json,
      :concurrency,
      :timeout_ms,
      :max_time_ms,
      :max_tasks,
      :max_tokens,
      :max_cost_usd,
      :local_server,
      :reasoning_effort
    ]

    if Enum.all?(Keyword.keys(parsed), &(&1 in allowed)) do
      with {:ok, prompt} <- matrix_prompt(parsed, options),
           {:ok, project} <- discover_project(options),
           {:ok, report} <-
             matrix_api(options).run(
               project,
               prompt,
               Keyword.get_values(parsed, :cell),
               matrix_options(parsed, options)
             ) do
        print_matrix_report(report, parsed[:json] || false)
      else
        {:error, {:validation, message}} ->
          IO.puts(:stderr, "ERROR: #{message}")
          2

        {:error, reason} ->
          IO.puts(:stderr, "ERROR: #{format_error(reason)}")
          1
      end
    else
      invalid_command_options(parsed)
    end
  end

  defp dispatch_command(_arguments, parsed, _options) when parsed != [] do
    options = parsed |> Keyword.keys() |> Enum.map_join(" ", &"--#{&1}")
    IO.puts(:stderr, "ERROR: Options are not valid for this command: #{options}")
    2
  end

  defp dispatch_command(arguments, _parsed, _options) do
    IO.puts(:stderr, "ERROR: Unknown command: #{Enum.join(arguments, " ")}")
    IO.puts(:stderr, "Run 'hancho --help' for usage.")
    2
  end

  defp run_or_preview(runner, project, workflow, source, count, parsed, options) do
    if parsed[:dry_run] do
      runner.preview(project, workflow, source, count, options)
    else
      runner.run(project, workflow, source, count, options)
    end
  end

  defp print_queue_output(preview, true) do
    count = length(preview.issues)
    noun = if count == 1, do: "task", else: "tasks"
    IO.puts("Dry run: #{preview.workflow} selected #{count} #{noun} from #{preview.source}.")
    IO.puts("Repository: #{preview.repository.branch} at #{preview.repository.head} (clean)")
    IO.puts("Retained worktrees: #{length(preview.repository.worktrees)}")
    IO.puts("Provider: #{preview.settings.provider || "not configured"}")
    IO.puts("Model: #{configured_model(Map.get(preview.settings, :model))}")
    IO.puts("Reasoning effort: #{preview.settings.reasoning_effort || "not configured"}")

    IO.puts(
      "Timeouts: implement #{format_milliseconds(preview.settings.implementation_timeout_ms)}, " <>
        "verify #{format_milliseconds(preview.settings.verification_timeout_ms)}"
    )

    Enum.each(preview.settings.repairs, fn repair ->
      noun = if repair.max_attempts == 1, do: "attempt", else: "attempts"

      IO.puts(
        "Repair: #{repair.step} via #{repair.provider}, #{repair.max_attempts} #{noun} " <>
          "(#{Enum.join(repair.codes, ", ")})"
      )
    end)

    preview.issues
    |> Enum.with_index(1)
    |> Enum.each(fn {issue, position} ->
      title = if is_binary(issue["title"]), do: " — #{issue["title"]}", else: ""
      IO.puts("#{position}. #{issue["id"]}#{title}")
    end)

    0
  end

  defp print_queue_output(result, false), do: print_queue_result(result)

  defp format_milliseconds(value) when is_integer(value), do: "#{value} ms"
  defp format_milliseconds(_value), do: "not configured"

  defp configured_model(value) when is_binary(value), do: "#{value} (configured)"
  defp configured_model(_value), do: "not configured (provider default; not pinned)"

  defp print_usage do
    IO.puts(@usage)
    0
  end

  defp print_version do
    IO.puts(Hancho.version())
    0
  end

  defp invalid_option({option, _value}) do
    IO.puts(:stderr, "ERROR: Unknown option: #{option}")
    IO.puts(:stderr, "Run 'hancho --help' for usage.")
    2
  end

  defp print_workflow_result(%Hancho.Workflow.Result{status: :completed} = result) do
    IO.puts("Workflow #{result.workflow} completed. Run: #{result.run_id}")
    0
  end

  defp print_workflow_result(%Hancho.Workflow.Result{status: :stopped} = result) do
    IO.puts(
      :stderr,
      "ERROR: Workflow #{result.workflow} stopped at #{result.current_step}: #{format_error(result.error)}"
    )

    if result.forensic_report, do: IO.puts(:stderr, "Forensic report: #{result.forensic_report}")

    1
  end

  defp print_queue_result(%Hancho.Workflow.QueueResult{status: :completed} = result) do
    print_queue_summary(result)
    0
  end

  defp print_queue_result(%Hancho.Workflow.QueueResult{status: :stopped} = result) do
    IO.puts(
      :stderr,
      "ERROR: Queue #{result.queue_id} stopped at #{result.current_issue}: #{format_error(result.error)}"
    )

    if result.forensic_report, do: IO.puts(:stderr, "Forensic report: #{result.forensic_report}")
    print_queue_summary(result, :stderr)

    1
  end

  defp print_queue_summary(result, device \\ :stdio) do
    if result.elapsed_ms || result.task_summaries != [] do
      IO.puts(
        device,
        "Queue summary: #{result.completed_count}/#{result.total_count} tasks, #{format_duration(result.elapsed_ms)} elapsed"
      )

      Enum.each(result.task_summaries, fn task ->
        model = task["model"] || "provider default; not pinned"

        IO.puts(
          device,
          "- #{task["issue_id"]}: #{format_duration(task["elapsed_ms"])}; #{task["provider"] || "no provider"}; #{model}; #{task_usage(task["usage"])}"
        )
      end)

      IO.puts(device, queue_usage(result.usage_summary))
    end
  end

  defp task_usage(%{"status" => "available"} = usage) do
    total = get_in(usage, ["values", "total_tokens"])
    suffix = if is_number(total), do: ", #{total} total tokens", else: ""
    "usage #{usage["scope"]}#{suffix}"
  end

  defp task_usage(_usage), do: "usage unavailable"

  defp queue_usage(%{"status" => "available", "values" => values}),
    do: "Queue usage: additive run totals #{inspect(values)}"

  defp queue_usage(%{"status" => "partial", "values" => values} = usage) do
    "Queue usage: additive totals #{inspect(values)}; #{usage["excluded_task_count"]} non-additive task values excluded"
  end

  defp queue_usage(%{"status" => "non_additive"} = usage) do
    "Queue usage: provider-cumulative or unknown values; #{usage["excluded_task_count"]} task values not added"
  end

  defp queue_usage(_usage), do: "Queue usage: unavailable"

  defp print_run_report(report) do
    location = if report.current_step, do: " at #{report.current_step}", else: ""
    IO.puts("Run: #{report.run_id}")
    IO.puts("Workflow: #{report.workflow}")
    IO.puts("Status: #{report.status}#{location}")
    IO.puts("Started: #{report.started_at}")
    IO.puts("Finished: #{report.finished_at || "running"}")
    IO.puts("Duration: #{format_duration(report.duration_ms)}")
    print_provider(report.provider)
    print_verification(report.verification)
    IO.puts("Commit: #{report.commit || "none"}")
    IO.puts("Retained worktree: #{report.retained_worktree || "none"}")
    IO.puts("Forensic report: #{report.forensic_report || "none"}")
    if report.failure, do: IO.puts("Failure: #{format_error(report.failure)}")
    print_effects(Map.get(report, :effects, []))
    IO.puts("Steps:")

    Enum.each(report.steps, fn step ->
      IO.puts(
        "#{step.position + 1}. #{step.name}: #{step.status} (#{format_duration(step.duration_ms)})"
      )

      if operation = Map.get(step, :operation) do
        history_count = length(Map.get(operation, "history", []))

        IO.puts("   Operation: #{operation["kind"]} #{operation["id"]} (#{history_count} prior)")
      end

      Enum.each(Map.get(step, :repairs, []), fn repair ->
        provider = repair["provider"] || "unknown provider"
        attempt = repair["attempt"] || "?"
        IO.puts("   Repair #{attempt}: #{repair["status"]} via #{provider}")
      end)
    end)

    0
  end

  defp print_effects([]), do: IO.puts("Effects: none")

  defp print_effects(effects) do
    IO.puts("Effects:")

    Enum.each(effects, fn effect ->
      IO.puts(
        "- Step #{effect["step_position"] + 1}: #{effect["kind"]} #{effect["status"]} " <>
          "(attempt #{effect["attempt"]})"
      )
    end)
  end

  defp print_worktree_list([]) do
    IO.puts("No retained Hancho worktrees.")
    0
  end

  defp print_worktree_list(reports) do
    Enum.each(reports, fn
      %{error: error} = report ->
        IO.puts("#{report.id}: error #{format_error(error)}")

      report ->
        state = if report.clean, do: "clean", else: "changed"
        IO.puts("#{report.id}: #{state}, #{report.size_bytes} bytes")
    end)

    0
  end

  defp print_worktree(report) do
    IO.puts("Worktree: #{report.id}")
    IO.puts("Path: #{report.path}")
    IO.puts("Registered: #{yes_no(report.registered)}")
    IO.puts("Detached: #{yes_no(report.detached)}")
    IO.puts("Head: #{report.head || "unknown"}")
    IO.puts("Status: #{if(report.clean, do: "clean", else: "changed")}")
    IO.puts("Size: #{report.size_bytes} bytes")
    IO.puts("Generated: #{report.generated_bytes} bytes")
    IO.puts("Changed paths: #{length(report.changed_paths)}")
    Enum.each(report.changed_paths, &IO.puts("- #{&1}"))
    0
  end

  defp discover_project(options) do
    project_api = Keyword.get(options, :project_api, Hancho.Project)
    project_api.discover(cwd: Keyword.get(options, :cwd, File.cwd!()))
  end

  defp worktrees_api(options), do: Keyword.get(options, :worktrees_api, Hancho.Worktrees)
  defp demands_api(options), do: Keyword.get(options, :demands_api, Hancho.Demands)
  defp models_api(options), do: Keyword.get(options, :models_api, Hancho.ModelDiscovery)
  defp matrix_api(options), do: Keyword.get(options, :matrix_api, Hancho.MatrixRun)

  defp matrix_prompt(parsed, options) do
    case {parsed[:task], parsed[:task_file]} do
      {task, nil} when is_binary(task) ->
        {:ok, task}

      {nil, path} when is_binary(path) ->
        cwd = Keyword.get(options, :cwd, File.cwd!())

        case File.read(Path.expand(path, cwd)) do
          {:ok, task} -> {:ok, task}
          {:error, reason} -> {:error, {:validation, "Cannot read the task file: #{reason}."}}
        end

      {nil, nil} ->
        {:error, {:validation, "Matrix run requires --task or --task-file."}}

      {_task, _path} ->
        {:error, {:validation, "Use only one of --task or --task-file."}}
    end
  end

  defp matrix_options(parsed, options) do
    parsed_options =
      [
        :concurrency,
        :timeout_ms,
        :max_time_ms,
        :max_tasks,
        :max_tokens,
        :max_cost_usd,
        :local_server,
        :reasoning_effort
      ]
      |> Enum.reduce([], fn key, values ->
        case Keyword.fetch(parsed, key) do
          {:ok, value} -> Keyword.put(values, key, value)
          :error -> values
        end
      end)

    Keyword.merge(options, parsed_options)
  end

  defp print_matrix_report(report, true) do
    IO.puts(Jason.encode!(report, pretty: true))
    matrix_exit_status(report)
  end

  defp print_matrix_report(report, false) do
    IO.puts(Hancho.MatrixRun.Report.human(report))
    matrix_exit_status(report)
  end

  defp matrix_exit_status(%{"status" => "completed"}), do: 0
  defp matrix_exit_status(_report), do: 1

  defp demand_options(options) do
    Keyword.take(options, [
      :github,
      :beadwork,
      :github_options,
      :beadwork_options,
      :cache,
      :lease_api
    ])
  end

  defp invalid_command_options(parsed) do
    names = parsed |> Keyword.keys() |> Enum.map_join(" ", &"--#{&1}")
    IO.puts(:stderr, "ERROR: Options are not valid for this command: #{names}")
    2
  end

  defp print_demands(result) do
    IO.puts("Outstanding demands for #{result.repository} (#{result.source}):")

    if result.records == [] do
      IO.puts("No outstanding demands.")
    else
      Enum.each(result.records, fn record ->
        github = if record.github_number, do: "##{record.github_number}", else: "no GitHub Issue"
        beadwork = record.beadwork_id || "no Beadwork record"

        IO.puts(
          "#{record.mapping_status} #{record.kind} #{github} <-> #{beadwork} — #{record.title}"
        )
      end)
    end

    0
  end

  defp print_demand_audit(result) do
    IO.puts("Demand mapping audit for #{result.repository}:")

    if result.findings == [] do
      IO.puts("No mapping findings.")
      0
    else
      Enum.each(result.findings, fn finding ->
        IO.puts(
          "#{String.upcase(finding.severity)} #{finding.code} #{finding.identity}: #{finding.message}"
        )
      end)

      if Enum.any?(result.findings, &(&1.severity == "error")), do: 1, else: 0
    end
  end

  defp print_demand_sync(result) do
    label = if result.mode == :dry_run, do: "Dry run", else: "Applied"
    IO.puts("#{label}: #{length(result.actions)} demand mapping actions.")
    Enum.each(result.actions, &IO.puts("- #{&1}"))
    0
  end

  defp command_error(reason) do
    IO.puts(:stderr, "ERROR: #{format_error(reason)}")
    1
  end

  defp yes_no(true), do: "yes"
  defp yes_no(_value), do: "no"

  defp print_provider(nil), do: IO.puts("Provider: not started")

  defp print_provider(provider) do
    identity = provider["harness_run_id"] || "unknown run"
    IO.puts("Provider: #{provider["provider"]} #{provider["status"]} (#{identity})")
    IO.puts("Model: #{configured_model(provider["model"])}")
    print_provider_usage(provider["usage"])
  end

  defp print_provider_usage(nil), do: :ok

  defp print_provider_usage(%{"status" => "unavailable"}),
    do: IO.puts("Provider usage: unavailable")

  defp print_provider_usage(usage) do
    total = get_in(usage, ["values", "total_tokens"])
    detail = if is_number(total), do: ", #{total} total tokens", else: ""
    IO.puts("Provider usage: #{usage["scope"]}#{detail}")
  end

  defp print_verification(nil), do: IO.puts("Verification: not started")

  defp print_verification(verification) do
    summary = if verification.summary, do: " — #{verification.summary}", else: ""
    IO.puts("Verification: exit #{verification.exit_status}#{summary}")
    if verification.output_path, do: IO.puts("Verification output: #{verification.output_path}")
  end

  defp format_duration(value) when is_integer(value), do: "#{value} ms"
  defp format_duration(_value), do: "unknown"

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
