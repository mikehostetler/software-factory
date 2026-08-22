defmodule Hancho.CollaborationTest do
  use ExUnit.Case, async: false

  alias Hancho.Workflow.{ArtifactSpec, Definition, Loader, RoleResolver, Store}

  defmodule CockpitStore do
    def open(_path), do: {:ok, "store"}
    def list_runs(_store), do: {:ok, [%{"id" => "run-1", "status" => "running"}]}
    def list_queues(_store), do: {:ok, []}
    def list_handoffs(_store), do: {:ok, []}
    def list_attention(_store), do: {:ok, [%{"id" => "gate-1", "status" => "pending"}]}
  end

  defmodule RoleHarness do
    def run(provider, prompt, options) do
      send(self(), {:harness_options, provider, prompt, options})

      {:ok,
       Jido.Harness.RunResult.new!(%{
         run_id: "role-run",
         provider: provider,
         status: :completed,
         text: "done",
         usage: %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}
       })}
    end
  end

  defmodule AttentionStore do
    def request_attention(_store, attributes) do
      {:ok,
       Process.get(:attention_record) ||
         %{
           "id" => attributes.id,
           "kind" => attributes.kind,
           "title" => attributes.title,
           "status" => "pending",
           "response" => nil
         }}
    end
  end

  test "loads inline and file role prompts and snapshots file content" do
    project = project()
    File.mkdir_p!(project.workflows_path)
    File.mkdir_p!(Path.join(project.hancho_dir, "prompts"))
    File.write!(Path.join(project.hancho_dir, "prompts/reviewer.md"), "Review carefully.")

    File.write!(Path.join(project.workflows_path, "roles.yaml"), """
    name: roles
    version: 1
    roles:
      coder:
        provider: codex
        prompt: |
          Write the smallest correct change.
        model: gpt-5.6-codex
        reasoning_effort: high
        cli: /usr/local/bin/codex
      reviewer:
        provider: grok
        prompt_file: reviewer.md
    steps:
      - name: code
        role: coder
        action: Hancho.Actions.Implement
        params:
          worktree_path: /tmp/work
          timeout_ms: 1000
    """)

    assert {:ok, definition, source} = Loader.load_with_source(project, "roles")
    assert definition.roles["reviewer"].prompt == "Review carefully."
    assert definition.roles["reviewer"].prompt_file == nil
    assert source.yaml =~ "Review carefully."

    params = RoleResolver.params(definition, hd(definition.steps))
    assert params["provider"] == "codex"
    assert params["model"] == "gpt-5.6-codex"
    assert params["reasoning_effort"] == "high"
    assert params["cli"] == "/usr/local/bin/codex"
    assert params["prompt"] =~ "smallest correct change"
  end

  test "validates declared typed artifact flow" do
    assert {:ok, definition} =
             Definition.new(%{
               name: "typed",
               version: 1,
               artifacts: %{
                 "specification" => %{
                   type: "object",
                   required: ["gherkin"],
                   properties: %{"gherkin" => "string"}
                 }
               },
               steps: [
                 %{name: "specify", action: "Test.Specify", produces: "specification"},
                 %{
                   name: "code",
                   action: "Test.Code",
                   consumes: ["specification"],
                   params: %{spec: "$artifacts.specification.gherkin"}
                 }
               ]
             })

    spec = definition.artifacts["specification"]
    assert :ok = ArtifactSpec.validate(spec, %{"gherkin" => "Feature: cache"})

    assert {:error, {:artifact_required_field_missing, "gherkin"}} =
             ArtifactSpec.validate(spec, %{})

    assert {:error, message} =
             Definition.new(%{
               name: "bad",
               version: 1,
               artifacts: %{"specification" => %{}},
               steps: [%{name: "code", action: "Test.Code", consumes: ["specification"]}]
             })

    assert message =~ "unavailable artifact"
  end

  test "stores durable handoffs and attention decisions" do
    project = project()
    assert {:ok, store} = Store.open(project.bedrock_path)

    assert :ok =
             Store.create_handoff(store, "run-1", %{
               from_role: "specifier",
               to_role: "coder",
               from_step: "specify",
               to_step: "code",
               artifact: "specification",
               payload: %{gherkin: "Feature: cache"}
             })

    assert {:ok, [handoff]} = Store.list_handoffs(store)
    assert handoff["status"] == "ready"
    assert handoff["to_role"] == "coder"
    assert :ok = Store.accept_handoff(store, "run-1", "code")
    assert :ok = Store.complete_handoff(store, "run-1", "code")

    assert {:ok, [%{"status" => "completed", "accepted_at" => accepted_at}]} =
             Store.list_handoffs(store)

    assert accepted_at

    request = %{
      id: "run-1:attention:approve_spec",
      run_id: "run-1",
      step: "approve_spec",
      role: "specifier",
      kind: "approval",
      title: "Approve the specification",
      body: "Review the Gherkin artifact."
    }

    assert {:ok, %{"status" => "pending"}} = Store.request_attention(store, request)

    assert {:ok, %{"status" => "approved", "response" => "looks good"}} =
             Store.resolve_attention(store, request.id, "approved", "looks good")

    assert {:ok, [attention]} = Store.list_attention(store)
    assert attention["resolved_at"]
  end

  test "builds a cockpit state and a local operator page" do
    project = project()
    assert {:ok, state} = Hancho.Cockpit.state(project, store_api: CockpitStore)
    assert hd(state.runs)["id"] == "run-1"
    assert hd(state.attention)["status"] == "pending"
    assert Hancho.Cockpit.page() =~ "Hancho Cockpit"
    assert Hancho.Cockpit.page() =~ "Role handoffs"
  end

  test "uses writable Mix paths in each isolated worktree" do
    project = project()
    first_workspace = Path.join(project.root, ".hancho/worktrees/run-1")
    second_workspace = Path.join(project.root, ".hancho/worktrees/run-2")
    File.mkdir_p!(first_workspace)
    File.mkdir_p!(second_workspace)

    assert {:ok, first} = Hancho.WorktreeSetup.prepare(first_workspace)
    assert {:ok, second} = Hancho.WorktreeSetup.prepare(second_workspace)

    assert first.env != second.env
    assert first.env["MIX_DEPS_PATH"] == Path.join(first_workspace, "deps")
    assert first.env["MIX_BUILD_PATH"] == Path.join(first_workspace, "_build")
    assert second.env["MIX_DEPS_PATH"] == Path.join(second_workspace, "deps")
    assert second.env["MIX_BUILD_PATH"] == Path.join(second_workspace, "_build")

    File.write!(Path.join(first.env["MIX_DEPS_PATH"], "local.bin"), "first")
    refute File.exists?(Path.join(second.env["MIX_DEPS_PATH"], "local.bin"))

    unsafe_workspace = Path.join(project.root, ".hancho/worktrees/run-unsafe")
    outside = Path.join(project.root, "outside-deps")
    File.mkdir_p!(unsafe_workspace)
    File.mkdir_p!(outside)
    File.ln_s!(outside, Path.join(unsafe_workspace, "deps"))

    assert {:error, {:mix_path_is_symlink, "deps"}} =
             Hancho.WorktreeSetup.prepare(unsafe_workspace)
  end

  test "passes role CLI, model, reasoning, and worktree Mix paths to Harness" do
    project = project()

    assert {:ok, result} =
             Hancho.Actions.Implement.run(
               %{
                 prompt: "Implement it.",
                 worktree_path: project.root,
                 provider: "codex",
                 cli: "/opt/tools/codex",
                 model: "gpt-test",
                 extra_args: [],
                 reasoning_effort: "high",
                 timeout_ms: 1_000,
                 idle_timeout_ms: 1_000,
                 andon_warning_ms: 500,
                 progress_interval_ms: 250
               },
               %{services: %{harness: RoleHarness}}
             )

    assert result.model == "gpt-test"
    assert result.model_source == "configured"
    assert result.usage["scope"] == "run"
    assert result.usage["additive"]
    assert_receive {:harness_options, :codex, "Implement it.", options}
    assert options[:model] == "gpt-test"
    assert options[:reasoning_effort] == :high
    assert options[:provider_options][:cli_path] == "/opt/tools/codex"
    assert options[:env]["MIX_DEPS_PATH"]
  end

  test "passes Claude credential deny settings through Harness" do
    project = project()

    assert {:ok, result} =
             Hancho.Actions.Implement.run(
               %{
                 prompt: "Implement it.",
                 worktree_path: project.root,
                 provider: "claude",
                 timeout_ms: 1_000,
                 idle_timeout_ms: 1_000,
                 andon_warning_ms: 500,
                 progress_interval_ms: 250
               },
               %{services: %{harness: RoleHarness}}
             )

    assert result.credential_protection.enforced
    assert result.credential_protection.profile == "claude_permission_rules"
    assert_receive {:harness_options, :claude, "Implement it.", options}
    settings = Jason.decode!(options[:provider_options][:settings])
    rules = get_in(settings, ["permissions", "deny"])
    assert Enum.any?(rules, &String.contains?(&1, ".ssh/id_*"))
    assert Enum.any?(rules, &String.contains?(&1, ".aws/credentials"))
  end

  test "attention action waits and then returns the durable answer" do
    context = %{
      run_id: "run-1",
      step: "question",
      role: "reviewer",
      effect_store: %{api: AttentionStore, store: "store", run_id: "run-1", step_position: 1}
    }

    params = %{kind: "clarification", title: "Choose adapter", body: "Which adapter?"}

    assert {:error, %{code: "attention_required", attention_id: id}} =
             Hancho.Actions.RequestAttention.run(params, context)

    Process.put(:attention_record, %{
      "id" => id,
      "kind" => "clarification",
      "title" => "Choose adapter",
      "status" => "answered",
      "response" => "Use the current adapter."
    })

    assert {:ok, %{status: "answered", response: "Use the current adapter."}} =
             Hancho.Actions.RequestAttention.run(params, context)

    Process.delete(:attention_record)
  end

  defp project do
    path =
      Path.join(System.tmp_dir!(), "hancho-collaboration-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)

    on_exit(fn ->
      Hancho.State.Bedrock.reset()
      File.rm_rf!(path)
    end)

    Hancho.Project.new(path)
  end
end
