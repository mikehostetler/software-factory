defmodule Hancho.WorkflowCompilerTest do
  use ExUnit.Case, async: false

  alias Hancho.Workflow.{Compiler, Definition, Loader, Runner}

  defmodule ReadyHarness do
    def status(provider) do
      Jido.Harness.ProviderStatus.new(%{
        provider: provider,
        installed: true,
        compatible: true,
        authenticated: true,
        smoke_ready: true
      })
    end
  end

  defmodule DynamicRegistry do
    def fetch("Test.Unloaded"), do: {:ok, Process.get({__MODULE__, :action})}
  end

  test "compiles the full workflow and its local dependencies" do
    project = project()
    assert :ok = Hancho.Workflow.Default.install(project)
    assert {:ok, definition} = Loader.load(project, "implement")

    assert {:ok, compiled} =
             Compiler.compile(
               project,
               definition,
               %{"repo_path" => project.root, "issue_id" => "hancho-123"},
               services: %{harness: ReadyHarness}
             )

    assert compiled.provider == "codex"
    assert length(compiled.steps) == 11

    implement = Enum.find(definition.steps, &(&1.name == "implement"))
    params = Hancho.Workflow.RoleResolver.params(definition, implement)
    assert params["provider"] == "codex"
    assert params["reasoning_effort"] == "xhigh"

    assert Enum.find(compiled.steps, &(&1.name == "validate_scope")).environment == %{
             repair_provider: "codex"
           }

    assert Enum.any?(compiled.executables, &String.ends_with?(&1, "/mix"))
    assert compiled.prompt_files == ["implement.md"]
  end

  test "rejects action parameter and input errors before state starts" do
    project = project()
    File.mkdir_p!(project.workflows_path)

    workflow = """
    name: invalid
    version: 1
    steps:
      - name: preflight
        action: Hancho.Actions.Preflight
        params:
          repo_path: "$input.missing"
          typo: value
    """

    File.write!(Path.join(project.workflows_path, "invalid.yaml"), workflow)

    assert {:error,
            {:workflow_compile_failed, "preflight", {:missing_input_reference, "$input.missing"}}} =
             Runner.run(project, "invalid", %{"repo_path" => project.root}, log: :disabled)

    refute File.exists?(project.bedrock_path)
  end

  test "loads an action before it validates required parameters" do
    project = project()
    action = unloaded_action(project)
    Process.put({DynamicRegistry, :action}, action)
    refute Code.loaded?(action)

    on_exit(fn -> Process.delete({DynamicRegistry, :action}) end)

    {:ok, workflow} =
      Definition.new(%{
        name: "missing-land-branch",
        version: 1,
        steps: [
          %{
            name: "land",
            action: "Test.Unloaded",
            params: %{
              repo_path: project.root,
              baseline: String.duplicate("a", 40),
              commit: String.duplicate("b", 40)
            }
          }
        ]
      })

    assert {:error, {:workflow_compile_failed, "land", {:missing_action_params, [:branch]}}} =
             Compiler.compile(project, workflow, %{},
               registry: DynamicRegistry,
               validate_environment: false
             )

    assert Code.loaded?(action)
  end

  test "rejects unknown providers and missing prompt files" do
    project = project()

    {:ok, provider_workflow} =
      Definition.new(%{
        name: "bad-provider",
        version: 1,
        steps: [
          %{
            name: "implement",
            action: "Hancho.Actions.Implement",
            params: %{
              prompt: "Do the work.",
              worktree_path: project.root,
              provider: "unknown",
              timeout_ms: 1_000
            }
          }
        ]
      })

    assert {:error, {:workflow_compile_failed, "implement", message}} =
             Compiler.compile(project, provider_workflow, %{})

    assert message =~ "Unknown Jido.Harness provider"

    {:ok, prompt_workflow} =
      Definition.new(%{
        name: "bad-prompt",
        version: 1,
        steps: [
          %{
            name: "prompt",
            action: "Hancho.Actions.RenderPrompt",
            params: %{
              repo_path: project.root,
              prompt_file: "missing.md",
              context: %{}
            }
          }
        ]
      })

    assert {:error, {:workflow_compile_failed, "prompt", {:prompt_file_not_found, "missing.md"}}} =
             Compiler.compile(project, prompt_workflow, %{})
  end

  test "rejects an implementation workflow without an explicit workspace" do
    project = project()

    {:ok, workflow} =
      Definition.new(%{
        name: "unsafe-implement",
        version: 1,
        steps: [
          %{
            name: "implement",
            action: "Hancho.Actions.Implement",
            params: %{
              prompt: "Do the work.",
              worktree_path: project.root,
              provider: "codex",
              timeout_ms: 1_000
            }
          }
        ]
      })

    assert {:error, {:workflow_compile_failed, "implement", :workspace_not_declared}} =
             Compiler.compile(project, workflow, %{},
               services: %{harness: ReadyHarness},
               validate_environment: false
             )
  end

  defp project do
    path = Path.join(System.tmp_dir!(), "hancho-compiler-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)

    on_exit(fn ->
      Hancho.State.Bedrock.reset()
      File.rm_rf!(path)
    end)

    Hancho.Project.new(path)
  end

  defp unloaded_action(project) do
    action = Module.concat(__MODULE__, "UnloadedAction#{System.unique_integer([:positive])}")

    source = """
    defmodule #{inspect(action)} do
      use Jido.Action,
        name: "unloaded_action",
        description: "Test action loaded during workflow compilation",
        schema:
          Zoi.object(%{
            repo_path: Zoi.string() |> Zoi.min(1),
            branch: Zoi.string() |> Zoi.min(1),
            baseline: Zoi.string() |> Zoi.min(1),
            commit: Zoi.string() |> Zoi.min(1)
          })

      def run(params, _context), do: {:ok, params}
    end
    """

    compiled = Code.compile_string(source)
    {^action, beam} = List.keyfind(compiled, action, 0)
    directory = Path.join(project.root, "action_beams")
    File.mkdir_p!(directory)
    File.write!(Path.join(directory, Atom.to_string(action) <> ".beam"), beam)

    code_path = String.to_charlist(directory)
    true = :code.add_patha(code_path)
    :code.purge(action)
    :code.delete(action)

    on_exit(fn ->
      :code.purge(action)
      :code.delete(action)
      :code.del_path(code_path)
    end)

    action
  end
end
