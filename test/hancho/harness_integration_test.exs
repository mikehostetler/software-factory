defmodule Hancho.HarnessIntegrationTest do
  use ExUnit.Case, async: false

  alias Hancho.Workflow.{Runner, Store}

  @moduletag :integration

  defmodule Beadwork do
    def show(issue_id, _options), do: {:ok, issue(issue_id, "open")}
    def start(issue_id, _options), do: {:ok, issue(issue_id, "in_progress")}
    def comment(issue_id, _text, _options), do: {:ok, %{"id" => issue_id}}
    def close(issue_id, _options), do: {:ok, issue(issue_id, "closed")}
    def sync(_options), do: {:ok, "synced"}

    defp issue(issue_id, status) do
      %{
        "id" => issue_id,
        "title" => "Exercise the real harness lifecycle",
        "description" => "Create implemented.txt through the test adapter.",
        "type" => "task",
        "status" => status,
        "blocked_by" => []
      }
    end
  end

  defmodule Command do
    def run(_executable, ["test"], options) do
      if File.exists?(Path.join(options[:cwd], "implemented.txt")) do
        {:ok,
         %Hancho.Command.Result{
           stdout: "deterministic integration tests passed\n",
           stderr: "",
           exit_status: 0
         }}
      else
        {:error, :implementation_file_missing}
      end
    end
  end

  setup do
    providers = Application.get_env(:jido_harness, :providers)
    provider_config = Application.get_env(:jido_harness, :provider_config)
    :ok = Hancho.Harness.ensure_started()
    baseline_run_ids = Jido.Harness.Run.list() |> MapSet.new(& &1.run_id)

    Application.put_env(
      :jido_harness,
      :providers,
      Map.put(Map.new(providers || %{}), :codex, Hancho.TestHarnessAdapter)
    )

    on_exit(fn ->
      restore_env(:providers, providers)
      restore_env(:provider_config, provider_config)
      cleanup_runs(baseline_run_ids)
    end)

    :ok
  end

  @tag timeout: 120_000
  test "runs the implementation workflow through the real Jido.Harness lifecycle" do
    repository = temporary_repository()
    project = Hancho.Project.new(repository)
    journal_dir = Path.join(project.hancho_dir, "harness-journal")

    Application.put_env(:jido_harness, :provider_config, %{
      codex: %{retention: %{journal_dir: journal_dir}}
    })

    File.mkdir_p!(project.worktrees_path)
    assert :ok = Hancho.Workflow.Default.install(project)

    assert {:ok, result} =
             Runner.run(
               project,
               "implement",
               %{"repo_path" => repository, "issue_id" => "hancho-integration"},
               run_id: "full-harness-integration",
               log: :disabled,
               services: %{beadwork: Beadwork, command: Command}
             )

    assert result.status == :completed
    assert result.outputs["implement"]["status"] == "completed"
    assert result.outputs["implement"]["text"] == "hancho-test-adapter-ok"
    assert result.outputs["close_issue"]["status"] == "closed"

    harness_run_id = result.outputs["implement"]["harness_run_id"]
    assert {:ok, %{state: :completed, provider: :codex}} = Jido.Harness.Run.info(harness_run_id)
    assert {:ok, events} = Jido.Harness.Run.replay(harness_run_id, limit: 100)
    assert Enum.map(events, & &1.sequence) == Enum.to_list(1..length(events))
    assert Enum.count(events, &Jido.Harness.Event.run_terminal?/1) == 1
    assert Enum.any?(events, &(&1.type == :file_change))

    assert File.read!(Path.join(repository, "implemented.txt")) ==
             "implemented by the Jido.Harness test adapter\n"

    refute File.exists?(Path.join(project.worktrees_path, "full-harness-integration"))

    assert {:ok, store} = Store.open(project.bedrock_path)
    assert {:ok, run} = Store.fetch_run(store, "full-harness-integration")
    assert run["status"] == "completed"
    assert {:ok, steps} = Store.list_steps(store, "full-harness-integration")
    implement = Enum.find(steps, &(&1["name"] == "implement"))
    operation = Jason.decode!(implement["operation_json"])
    assert operation["kind"] == "jido_harness.run"
    assert operation["id"] == harness_run_id

    assert String.starts_with?(
             Jido.Harness.Run.info(harness_run_id) |> elem(1) |> Map.fetch!(:journal_dir),
             project.hancho_dir
           )

    assert :ok = Store.flush(store)
    assert :ok = Jido.Harness.Run.prune(harness_run_id)
  end

  defp cleanup_runs(baseline) do
    Jido.Harness.Run.list()
    |> Enum.reject(&MapSet.member?(baseline, &1.run_id))
    |> Enum.each(fn info ->
      unless Jido.Harness.RunInfo.terminal?(info), do: Jido.Harness.Run.cancel(info.run_id)
      _result = Jido.Harness.Run.prune(info.run_id)
    end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_harness, key)
  defp restore_env(key, value), do: Application.put_env(:jido_harness, key, value)

  defp temporary_repository do
    path =
      Path.join(
        System.tmp_dir!(),
        "hancho-harness-integration-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)

    on_exit(fn ->
      Hancho.State.Bedrock.reset()
      File.rm_rf!(path)
    end)

    {_output, 0} = System.cmd("git", ["init", "--initial-branch=main", path])
    File.write!(Path.join(path, ".gitignore"), "/.hancho/\n")
    {_output, 0} = System.cmd("git", ["-C", path, "add", ".gitignore"])

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
        "chore: initialize integration repository"
      ])

    path
  end
end
