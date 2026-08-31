defmodule Hancho.MatrixRunTest do
  use ExUnit.Case, async: false

  alias Jido.Harness.Event

  defmodule DeterministicHarness do
    def run_with_progress(provider, prompt, options, progress) do
      model = options[:model] || "default"
      run_id = "harness-#{provider}-#{model}"
      local_server = "http://127.0.0.1:4567"
      effective_model = if model == "alpha", do: "effective-alpha", else: nil
      total_tokens = if model == "alpha", do: 100, else: 20

      File.write!(Path.join(options[:cwd], "README.md"), "changed by #{model}\n")
      File.write!(Path.join(options[:cwd], "#{model}.txt"), prompt)

      events = [
        event(run_id, provider, 1, :run_started, %{"model" => effective_model}),
        event(run_id, provider, 2, :tool_call, %{
          "name" => "exec_command",
          "input" => %{"cmd" => "mix test"},
          "call_id" => "test"
        }),
        event(run_id, provider, 3, :tool_result, %{
          "output" => "4 tests, 0 failures",
          "call_id" => "test",
          "is_error" => false
        }),
        event(run_id, provider, 4, :tool_call, %{
          "name" => "exec_command",
          "input" => %{"cmd" => "curl #{local_server}/cart"},
          "call_id" => "local"
        }),
        event(run_id, provider, 5, :tool_result, %{
          "output" => "GET #{local_server}/cart -> 200",
          "call_id" => "local",
          "is_error" => false
        }),
        event(run_id, provider, 6, :file_change, %{"path" => "README.md"}),
        event(run_id, provider, 7, :usage, %{
          "input_tokens" => total_tokens - 5,
          "output_tokens" => 5,
          "total_tokens" => total_tokens,
          "cost_usd" => total_tokens / 1_000
        }),
        event(run_id, provider, 8, :output_text_final, %{"text" => "output #{model}"}),
        event(run_id, provider, 9, :run_completed, %{"cost_usd" => total_tokens / 1_000})
      ]

      progress.(%{harness_run_id: run_id, phase: :started})
      options[:event_callback].(events)

      {:ok,
       Jido.Harness.RunResult.new!(%{
         run_id: run_id,
         provider: provider,
         provider_session_id: "session-#{model}",
         status: :completed,
         text: "output #{model}",
         usage: %{
           "input_tokens" => total_tokens - 5,
           "output_tokens" => 5,
           "total_tokens" => total_tokens,
           "cost_usd" => total_tokens / 1_000
         },
         events: events
       })}
    end

    defp event(run_id, provider, sequence, type, payload) do
      Event.new!(
        provider: provider,
        provider_session_id: "session",
        type: type,
        payload: payload
      )
      |> Event.attach(run_id, provider, sequence)
    end
  end

  defmodule FailureHarness do
    def run_with_progress(provider, _prompt, options, progress) do
      run_id = "harness-failed"
      File.write!(Path.join(options[:cwd], "partial.txt"), "partial evidence\n")

      event =
        Event.new!(
          provider: provider,
          provider_session_id: "failed-session",
          type: :run_failed,
          payload: %{"error" => "deterministic provider failure"}
        )
        |> Event.attach(run_id, provider, 1)

      progress.(%{harness_run_id: run_id, phase: :started})
      options[:event_callback].([event])

      {:error,
       Jido.Harness.Error.execution("deterministic provider failure",
         provider: provider,
         run_id: run_id
       )}
    end
  end

  test "runs cells in isolated worktrees and saves comparable evidence" do
    project = temporary_project()

    assert {:ok, report} =
             Hancho.MatrixRun.run(
               project,
               "Test the cart without a purchase.",
               ["codex=alpha", "claude=beta"],
               harness: DeterministicHarness,
               concurrency: 2,
               local_server: "http://127.0.0.1:4567",
               matrix_run_id: "matrix-test"
             )

    assert report["status"] == "completed"
    assert report["task"]["source_task_count"] == 1
    assert report["task"]["harness_task_count"] == 2
    assert report["comparison"]["status"] == "incomplete"
    assert report["comparison"]["ranking"] == "not_performed"
    assert report["comparison"]["winner"] == nil
    assert Enum.any?(report["comparison"]["differences"], &(&1["field"] == "output"))

    [alpha, beta] = report["runs"]
    assert alpha["provider"] == "codex"
    assert alpha["requested_model"] == "alpha"
    assert alpha["evidence"]["effective_model"]["value"] == "effective-alpha"
    assert beta["evidence"]["effective_model"]["status"] == "unavailable"
    assert alpha["harness_run_id"] == "harness-codex-alpha"
    assert alpha["output"]["text"] == "output alpha"
    assert alpha["evidence"]["tool_activity"]["status"] == "observed"
    assert alpha["evidence"]["tests"]["status"] == "passed"
    assert alpha["evidence"]["local_server"]["status"] == "observed"
    assert alpha["evidence"]["file_changes"]["status"] == "observed"
    assert alpha["evidence"]["file_changes"]["patch"]["status"] == "available"
    assert alpha["usage"]["values"]["total_tokens"] == 100
    assert alpha["cost"]["value_usd"] == 0.1

    alpha_worktree = alpha["isolation"]["worktree"]
    beta_worktree = beta["isolation"]["worktree"]
    assert alpha_worktree != beta_worktree
    assert File.read!(Path.join(alpha_worktree, "README.md")) == "changed by alpha\n"
    assert File.read!(Path.join(beta_worktree, "README.md")) == "changed by beta\n"
    assert File.read!(Path.join(project.root, "README.md")) == "baseline\n"

    assert File.exists?(get_in(report, ["artifacts", "json"]))
    assert File.exists?(get_in(report, ["artifacts", "comparison"]))
    assert Jason.decode!(File.read!(get_in(report, ["artifacts", "json"]))) == report
    assert File.read!(get_in(report, ["artifacts", "comparison"])) =~ "Ranking: **not_performed**"
  end

  test "stops new cells after a measurable token limit" do
    project = temporary_project()

    assert {:ok, report} =
             Hancho.MatrixRun.run(
               project,
               "Make a fixed local change.",
               ["codex=alpha", "codex=beta", "claude=gamma"],
               harness: DeterministicHarness,
               concurrency: 1,
               max_tokens: 50,
               matrix_run_id: "matrix-limit"
             )

    assert report["status"] == "limit_reached"
    assert report["limits"]["stop_reason"] == "max_tokens"
    assert report["limits"]["observed_additive_tokens"] == 100
    assert Enum.map(report["runs"], & &1["status"]) == ["completed", "skipped", "skipped"]
    assert get_in(Enum.at(report["runs"], 1), ["failure", "limit"]) == "max_tokens"
  end

  test "stops new cells after a measurable cost limit" do
    project = temporary_project()

    assert {:ok, report} =
             Hancho.MatrixRun.run(
               project,
               "Make a fixed local change.",
               ["codex=alpha", "codex=beta"],
               harness: DeterministicHarness,
               concurrency: 1,
               max_cost_usd: 0.05,
               matrix_run_id: "matrix-cost-limit"
             )

    assert report["status"] == "limit_reached"
    assert report["limits"]["stop_reason"] == "max_cost_usd"
    assert report["limits"]["observed_additive_cost_usd"] == 0.1
    assert Enum.map(report["runs"], & &1["status"]) == ["completed", "skipped"]
  end

  test "keeps provider failures and partial file evidence" do
    project = temporary_project()

    assert {:ok, report} =
             Hancho.MatrixRun.run(project, "Fail in a fixed way.", ["codex=failure"],
               harness: FailureHarness,
               matrix_run_id: "matrix-failure"
             )

    assert report["status"] == "failed"
    assert report["comparison"]["status"] == "incomplete"
    assert report["comparison"]["winner"] == nil

    [run] = report["runs"]
    assert run["status"] == "failed"
    assert run["harness_run_id"] == "harness-failed"
    assert run["failure"]["message"] =~ "deterministic provider failure"
    assert run["evidence"]["file_changes"]["status"] == "observed"

    assert Enum.any?(run["evidence"]["file_changes"]["workspace"], fn change ->
             change["path"] == "partial.txt"
           end)
  end

  test "rejects excess tasks and non-loopback server targets" do
    project = temporary_project()

    assert {:error, {:validation, message}} =
             Hancho.MatrixRun.run(project, "Task", ["codex=a", "claude=b"], max_tasks: 1)

    assert message =~ "maximum task count"

    assert {:error, {:validation, message}} =
             Hancho.MatrixRun.run(project, "Task", ["codex=a"],
               local_server: "https://shop.example.com"
             )

    assert message =~ "host must be localhost"
  end

  defp temporary_project do
    root =
      Path.join(System.tmp_dir!(), "hancho-matrix-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    File.write!(Path.join(root, ".gitignore"), "/.hancho/\n/_build/\n/deps/\n")
    File.write!(Path.join(root, "README.md"), "baseline\n")

    {_output, 0} = System.cmd("git", ["init", "--initial-branch=main", root])
    {_output, 0} = System.cmd("git", ["-C", root, "add", "."])

    {_output, 0} =
      System.cmd("git", [
        "-C",
        root,
        "-c",
        "user.name=Hancho Test",
        "-c",
        "user.email=hancho@example.test",
        "-c",
        "commit.gpgsign=false",
        "commit",
        "-m",
        "Initial commit"
      ])

    on_exit(fn -> File.rm_rf!(root) end)
    Hancho.Project.new(root)
  end
end
