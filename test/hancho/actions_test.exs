defmodule Hancho.ActionsTest do
  use ExUnit.Case, async: false

  alias Hancho.Actions
  alias Hancho.Command.Result

  defmodule PreflightGit do
    def status(_options), do: {:ok, %Git.Status{branch: "main", entries: []}}
    def head(_options), do: {:ok, "abc123"}
  end

  defmodule PreflightBeadwork do
    def show("hancho-123", _options) do
      {:ok,
       %{
         "id" => "hancho-123",
         "title" => "Test task",
         "type" => "task",
         "status" => "open",
         "blocked_by" => []
       }}
    end
  end

  defmodule ClosedBlockerBeadwork do
    def show("hancho-123", _options) do
      {:ok,
       %{
         "id" => "hancho-123",
         "type" => "task",
         "status" => "open",
         "blocked_by" => ["hancho-122"]
       }}
    end

    def show("hancho-122", _options), do: {:ok, %{"id" => "hancho-122", "status" => "closed"}}
  end

  defmodule OpenBlockerBeadwork do
    def show("hancho-123", options), do: ClosedBlockerBeadwork.show("hancho-123", options)
    def show("hancho-122", _options), do: {:ok, %{"id" => "hancho-122", "status" => "open"}}
  end

  defmodule Harness do
    def run(:codex, prompt, options) do
      if prompt =~ "hancho-123" and
           options[:cwd] == "/repo/.hancho/worktrees/run-1" and
           options[:sandbox_mode] == :workspace_write and
           options[:approval_mode] == :auto_edit do
        {:ok,
         Jido.Harness.RunResult.new!(%{
           run_id: "harness-1",
           provider: :codex,
           status: :completed,
           text: "implemented"
         })}
      else
        {:error, :invalid_harness_request}
      end
    end
  end

  defmodule WorktreeSetup do
    def prepare(_workspace) do
      {:ok,
       %{
         env: %{"MIX_DEPS_PATH" => "/workspace/deps", "MIX_BUILD_PATH" => "/workspace/build"},
         deps_path: "/workspace/deps",
         build_path: "/workspace/build"
       }}
    end
  end

  defmodule FailingWorktreeSetup do
    def prepare(_workspace), do: {:error, :mix_path_not_writable}
  end

  defmodule MustNotRunHarness do
    def run(_provider, _prompt, _options) do
      send(self(), :unexpected_provider_run)
      {:error, :must_not_run}
    end
  end

  defmodule ProgressHarness do
    def run_with_progress(:codex, _prompt, options, callback) do
      25 = options[:progress_interval_ms]
      120_000 = options[:andon_warning_ms]
      nil = options[:event_callback]

      :ok =
        callback.(%{
          harness_run_id: "harness-progress",
          provider: :codex,
          phase: :started,
          elapsed_ms: 0,
          event_count: 0,
          last_event: nil
        })

      :ok =
        callback.(%{
          harness_run_id: "harness-progress",
          provider: :codex,
          phase: :andon,
          elapsed_ms: 120_005,
          inactivity_ms: 120_000,
          andon_warning_ms: 120_000,
          event_count: 3,
          last_event: :thinking_delta
        })

      :ok =
        callback.(%{
          harness_run_id: "harness-progress",
          provider: :codex,
          phase: :completed,
          elapsed_ms: 50,
          event_count: 4,
          last_event: :run_completed
        })

      {:ok,
       Jido.Harness.RunResult.new!(%{
         run_id: "harness-progress",
         provider: :codex,
         status: :completed,
         text: "implemented"
       })}
    end
  end

  defmodule VerboseHarness do
    def run_with_progress(:grok, _prompt, options, callback) do
      :auto_approve = options[:approval_mode]
      :workspace_write = options[:sandbox_mode]
      nil = options[:reasoning_effort]
      %{extra_args: ["--reasoning-effort=xhigh"]} = options[:provider_options]
      deny_rules = options[:provider_options][:deny_rules]
      true = Enum.any?(deny_rules, &String.contains?(&1, ".config/gh/hosts.yml"))
      true = Enum.any?(deny_rules, &String.contains?(&1, ".env"))
      event_callback = options[:event_callback]
      true = is_function(event_callback, 1)
      500 = options[:event_poll_interval_ms]

      :ok =
        event_callback.([
          event(:thinking_delta, %{"text" => "Inspect the"}, 1),
          event(:thinking_delta, %{"text" => " task.\n"}, 2),
          event(:output_text_delta, %{"text" => "I will update the fixture.\n"}, 3),
          event(
            :tool_call,
            %{
              "name" => "run_terminal_command",
              "call_id" => "call-123456789012345",
              "input" => %{"description" => "Run focused tests", "command" => "secret-command"}
            },
            4
          ),
          event(
            :tool_result,
            %{
              "call_id" => "call-123456789012345",
              "is_error" => false,
              "output" => "secret tool output"
            },
            5
          ),
          event(:usage, %{"total_tokens" => 1_234}, 6)
        ])

      :ok =
        callback.(%{
          harness_run_id: "harness-verbose",
          provider: :grok,
          phase: :completed,
          elapsed_ms: 50,
          event_count: 7,
          last_event: :run_completed
        })

      {:ok,
       Jido.Harness.RunResult.new!(%{
         run_id: "harness-verbose",
         provider: :grok,
         status: :completed,
         text: "implemented"
       })}
    end

    defp event(type, payload, sequence) do
      Jido.Harness.Event.new!(
        type: type,
        provider: :grok,
        sequence: sequence,
        payload: payload
      )
    end
  end

  defmodule Command do
    def run("/test/mix", ["test"], options) do
      if options[:cwd] == "/repo/worktree" do
        :ok = options[:on_output].(:stdout, "2 tests, 0 failures\n")
        {:ok, %Result{stdout: "2 tests, 0 failures\n", stderr: "", exit_status: 0}}
      else
        {:error, :invalid_command_options}
      end
    end
  end

  defmodule ChunkedCommand do
    def run("/test/mix", ["test"], options) do
      Enum.each(1..1_103, fn _index -> :ok = options[:on_output].(:stdout, ".") end)
      :ok = options[:on_output].(:stdout, "\nResult: 762 passed\n")

      {:ok,
       %Result{
         stdout: String.duplicate(".", 1_103) <> "\nResult: 762 passed\n",
         stderr: "",
         exit_status: 0
       }}
    end
  end

  test "executes preflight through Jido.Action validation" do
    context = %{services: %{git: PreflightGit, beadwork: PreflightBeadwork}}

    assert {:ok, result} =
             Jido.Exec.run(
               Actions.Preflight,
               %{repo_path: "/repo", issue_id: "hancho-123"},
               context
             )

    assert result.baseline == "abc123"
    assert result.branch == "main"
    assert result.issue["id"] == "hancho-123"
  end

  test "accepts closed blocker references and rejects open blockers" do
    input = %{repo_path: "/repo", issue_id: "hancho-123"}

    assert {:ok, _result} =
             Jido.Exec.run(
               Actions.Preflight,
               input,
               %{services: %{git: PreflightGit, beadwork: ClosedBlockerBeadwork}}
             )

    assert {:error, error} =
             Jido.Exec.run(
               Actions.Preflight,
               input,
               %{services: %{git: PreflightGit, beadwork: OpenBlockerBeadwork}}
             )

    assert Exception.message(error) =~ "blocked by hancho-122"
  end

  test "calls Jido.Harness with an approved provider and isolated worktree" do
    assert {:ok, result} =
             Jido.Exec.run(
               Actions.Implement,
               %{
                 prompt: "Implement hancho-123",
                 worktree_path: "/repo/.hancho/worktrees/run-1",
                 provider: "codex",
                 timeout_ms: 1_000
               },
               %{services: %{harness: Harness, worktree_setup: WorktreeSetup}}
             )

    assert result.status == :completed
    assert result.harness_run_id == "harness-1"
  end

  test "fails Mix path setup before provider execution" do
    assert {:error, :mix_path_not_writable} =
             Actions.Implement.run(
               %{
                 prompt: "Implement hancho-123",
                 worktree_path: "/repo/.hancho/worktrees/run-1",
                 provider: "codex",
                 timeout_ms: 1_000
               },
               %{
                 services: %{
                   harness: MustNotRunHarness,
                   worktree_setup: FailingWorktreeSetup
                 }
               }
             )

    refute_received :unexpected_provider_run
  end

  test "selects a clean repository as an explicit in-place workspace" do
    repository = temporary_repository()
    {:ok, baseline} = Hancho.Git.head(working_dir: repository)

    assert {:ok, workspace} =
             Jido.Exec.run(
               Actions.UseRepository,
               %{repo_path: repository, baseline: baseline},
               %{services: %{git: Hancho.Git}}
             )

    assert workspace == %{
             mode: "in_place",
             workspace_path: repository,
             baseline: baseline
           }

    File.write!(Path.join(repository, "unexpected.txt"), "dirty\n")

    assert {:error, error} =
             Jido.Exec.run(
               Actions.UseRepository,
               %{repo_path: repository, baseline: baseline},
               %{services: %{git: Hancho.Git}}
             )

    assert Exception.message(error) =~ "in-place workspace has uncommitted changes"
  end

  test "records normalized implementation progress without provider output" do
    repository = temporary_repository()
    project = Hancho.Project.new(repository)
    {:ok, config} = Hancho.Config.load(project)
    {:ok, log} = Hancho.Log.open(project, config)

    assert {:ok, result} =
             Jido.Exec.run(
               Actions.Implement,
               %{
                 prompt: "Implement hancho-123",
                 worktree_path: repository,
                 provider: "codex",
                 timeout_ms: 1_000,
                 progress_interval_ms: 25
               },
               %{services: %{harness: ProgressHarness, worktree_setup: WorktreeSetup}, log: log}
             )

    assert result.harness_run_id == "harness-progress"
    assert :ok = Hancho.Log.close(log)

    events =
      project
      |> then(&Path.join(&1.logs_path, "factory.jsonl"))
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)
      |> Enum.filter(&(&1["event"] == "implement.progress"))

    assert Enum.map(events, & &1["metadata"]["phase"]) == ["started", "completed"]
    assert List.last(events)["metadata"]["last_event"] == "run_completed"
    refute Enum.any?(events, &Map.has_key?(&1["metadata"], "text"))

    [andon] =
      project
      |> then(&Path.join(&1.logs_path, "factory.jsonl"))
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)
      |> Enum.filter(&(&1["event"] == "implement.andon"))

    assert andon["level"] == "warning"
    assert andon["metadata"]["inactivity_ms"] == 120_000

    assert andon["message"] ==
             "Implementation Andon: no provider activity for 120 seconds"
  end

  test "prints safe normalized provider events in verbose mode" do
    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert {:ok, result} =
                 Jido.Exec.run(
                   Actions.Implement,
                   %{
                     prompt: "Implement hancho-123",
                     worktree_path: "/repo",
                     provider: "grok",
                     reasoning_effort: "xhigh",
                     timeout_ms: 1_000,
                     progress_interval_ms: 25
                   },
                   %{
                     services: %{harness: VerboseHarness, worktree_setup: WorktreeSetup},
                     log: :disabled,
                     verbose: true
                   }
                 )

        assert result.harness_run_id == "harness-verbose"
      end)

    assert output =~ "[grok:thought] Inspect the task."
    assert output =~ "[grok] I will update the fixture."
    assert output =~ "[grok:tool] run_terminal_command — Run focused tests"
    assert output =~ "[grok:tool] completed"
    assert output =~ "[grok:usage] 1234 total tokens"
    refute output =~ "secret-command"
    refute output =~ "secret tool output"
  end

  test "renders inline and repository-local prompt snapshots" do
    repository = temporary_repository()
    prompts_path = Path.join([repository, ".hancho", "prompts"])
    File.mkdir_p!(prompts_path)
    File.write!(Path.join(prompts_path, "implement.md"), "Build {{issue.id}}: {{issue.title}}\n")

    context = %{log: :disabled, step: "render_prompt"}
    values = %{issue: %{"id" => "hancho-123", "title" => "Prompt support"}}

    assert {:ok, file_result} =
             Jido.Exec.run(
               Actions.RenderPrompt,
               %{repo_path: repository, prompt_file: "implement.md", context: values},
               context
             )

    assert file_result.source == "file"
    assert file_result.prompt_file == "implement.md"
    assert file_result.template == "Build {{issue.id}}: {{issue.title}}\n"
    assert file_result.rendered == "Build hancho-123: Prompt support\n"
    assert file_result.sha256 == sha256(file_result.rendered)

    assert {:ok, inline_result} =
             Jido.Exec.run(
               Actions.RenderPrompt,
               %{
                 repo_path: repository,
                 prompt: "Review {{issue.id}}",
                 context: values
               },
               context
             )

    assert inline_result.source == "inline"
    assert inline_result.prompt_file == nil
    assert inline_result.rendered == "Review hancho-123"
  end

  test "runs the configured verification command and captures its output" do
    repository = temporary_repository()

    assert {:ok, result} =
             Jido.Exec.run(
               Actions.Verify,
               %{
                 repo_path: repository,
                 worktree_path: "/repo/worktree",
                 executable: "/test/mix",
                 arguments: ["test"],
                 timeout_ms: 1_000
               },
               %{
                 services: %{command: Command, worktree_setup: WorktreeSetup},
                 log: :disabled
               }
             )

    assert result.exit_status == 0
    assert result.output =~ "0 failures"
    assert File.read!(result.output_path) == "2 tests, 0 failures\n"
    assert result.bytes == 20
    assert result.chunks == 1
  end

  test "coalesces verification chunks and retains complete raw output" do
    repository = temporary_repository()
    project = Hancho.Project.new(repository)
    {:ok, config} = Hancho.Config.load(project)
    {:ok, log} = Hancho.Log.open(project, config)

    assert {:ok, result} =
             Jido.Exec.run(
               Actions.Verify,
               %{
                 repo_path: repository,
                 worktree_path: repository,
                 executable: "/test/mix",
                 arguments: ["test"],
                 timeout_ms: 1_000
               },
               %{services: %{command: ChunkedCommand}, log: log, run_id: "run-verify"}
             )

    assert result.summary == "Result: 762 passed"
    assert result.chunks == 1_104

    assert File.read!(result.output_path) ==
             String.duplicate(".", 1_103) <> "\nResult: 762 passed\n"

    assert :ok = Hancho.Log.close(log)

    events =
      project
      |> then(&Path.join(&1.logs_path, "factory.jsonl"))
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)

    refute Enum.any?(events, &(&1["event"] == "verify.stdout"))
    assert Enum.count(events, &(&1["event"] == "verify.completed")) == 1
    assert Enum.count(events, &(&1["event"] == "verify.progress")) == 0
  end

  test "validates changed paths against the Beadwork Allowed Scope" do
    repository = temporary_repository()
    File.mkdir_p!(Path.join(repository, "lib/hancho"))
    File.write!(Path.join(repository, "lib/hancho/feature.ex"), "feature\n")
    File.write!(Path.join(repository, "README.md"), "unexpected\n")

    issue = %{
      "description" => """
      ## Allowed Scope

      - `lib/hancho/`
      - `test/hancho/scope_test.exs`

      ## Verification

      - `mix test`
      """
    }

    assert {:error, error} =
             Jido.Exec.run(
               Actions.ValidateScope,
               %{worktree_path: repository, issue: issue},
               %{services: %{git: Hancho.Git}}
             )

    assert Exception.message(error) =~ "changes_outside_allowed_scope"
    assert Exception.message(error) =~ "README.md"

    File.rm!(Path.join(repository, "README.md"))

    assert {:ok, result} =
             Jido.Exec.run(
               Actions.ValidateScope,
               %{worktree_path: repository, issue: issue},
               %{services: %{git: Hancho.Git}}
             )

    assert result.status == "checked"
    assert result.changed_paths == ["lib/hancho/feature.ex"]
  end

  test "skips scope validation when a ticket has no Allowed Scope section" do
    repository = temporary_repository()
    File.write!(Path.join(repository, "feature.txt"), "feature\n")

    assert {:ok, result} =
             Jido.Exec.run(
               Actions.ValidateScope,
               %{worktree_path: repository, issue: %{"description" => "Create feature.txt"}},
               %{services: %{git: Hancho.Git}}
             )

    assert result.status == "not_configured"
    assert result.changed_paths == ["feature.txt"]
  end

  test "creates, commits, lands, and removes a real detached worktree" do
    repository = temporary_repository()
    {:ok, baseline} = Hancho.Git.head(working_dir: repository)
    context = %{services: %{git: Hancho.Git}}

    assert {:ok, created} =
             Jido.Exec.run(
               Actions.CreateWorktree,
               %{repo_path: repository, baseline: baseline, run_id: "run-1"},
               context
             )

    File.write!(Path.join(created.worktree_path, "feature.txt"), "factory\n")

    issue = %{"id" => "hancho-123", "title" => "Add factory feature"}

    assert {:ok, committed} =
             Jido.Exec.run(
               Actions.Commit,
               %{worktree_path: created.worktree_path, baseline: baseline, issue: issue},
               context
             )

    assert committed.commit != baseline

    assert {:ok, landed} =
             Jido.Exec.run(
               Actions.Land,
               %{
                 repo_path: repository,
                 branch: "main",
                 baseline: baseline,
                 commit: committed.commit
               },
               context
             )

    assert landed.commit == committed.commit
    assert File.read!(Path.join(repository, "feature.txt")) == "factory\n"

    assert {:ok, removed} =
             Jido.Exec.run(
               Actions.RemoveWorktree,
               %{repo_path: repository, worktree_path: created.worktree_path},
               context
             )

    assert removed.removed
    refute File.exists?(created.worktree_path)
  end

  test "refuses to land on a branch other than the preflight branch" do
    repository = temporary_repository()
    {:ok, baseline} = Hancho.Git.head(working_dir: repository)
    {_output, 0} = System.cmd("git", ["-C", repository, "switch", "-c", "other"])

    assert {:error, error} =
             Jido.Exec.run(
               Actions.Land,
               %{
                 repo_path: repository,
                 branch: "main",
                 baseline: baseline,
                 commit: baseline
               },
               %{services: %{git: Hancho.Git}},
               max_retries: 0
             )

    assert Exception.message(error) =~ "landing branch changed from main to other"
  end

  defp temporary_repository do
    path = Path.join(System.tmp_dir!(), "hancho-actions-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)

    {_output, 0} = System.cmd("git", ["init", "--initial-branch=main", path])
    File.write!(Path.join(path, ".gitignore"), "/.hancho/\n")

    {_output, 0} =
      System.cmd("git", [
        "-C",
        path,
        "-c",
        "user.name=Hancho Test",
        "-c",
        "user.email=hancho@example.test",
        "add",
        ".gitignore"
      ])

    {_output, 0} =
      System.cmd("git", [
        "-C",
        path,
        "-c",
        "user.name=Hancho Test",
        "-c",
        "user.email=hancho@example.test",
        "commit",
        "-m",
        "chore: initialize test repository"
      ])

    path
  end

  defp sha256(contents), do: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
end
