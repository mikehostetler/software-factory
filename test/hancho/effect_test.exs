defmodule Hancho.EffectTest do
  use ExUnit.Case, async: false

  alias Hancho.Workflow.{Definition, Effect, Store}

  defmodule ReceiptFailureStore do
    def begin_effect(store, run_id, position, key, kind, intent),
      do: Store.begin_effect(store, run_id, position, key, kind, intent)

    def complete_effect(store, run_id, position, key, receipt) do
      if Process.get(__MODULE__, true) do
        Process.put(__MODULE__, false)
        {:error, :simulated_crash_gap}
      else
        Store.complete_effect(store, run_id, position, key, receipt)
      end
    end

    def fail_effect(store, run_id, position, key, reason),
      do: Store.fail_effect(store, run_id, position, key, reason)
  end

  defmodule OrderedIntentStore do
    def begin_effect(store, _run_id, _position, _key, kind, intent) do
      send(store.owner, {:intent, kind, intent})
      {:ok, %{"status" => "intended"}}
    end

    def flush(store) do
      send(store.owner, :intent_flushed)
      store.flush_result
    end

    def complete_effect(store, _run_id, _position, _key, receipt) do
      send(store.owner, {:receipt, receipt})
      :ok
    end

    def fail_effect(_store, _run_id, _position, _key, _reason), do: :ok
  end

  test "reconciles an external effect after receipt persistence fails" do
    root = temporary_directory()
    project = Hancho.Project.new(root)
    marker = Path.join(root, "external-effect")
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    {:ok, definition} =
      Definition.new(%{
        name: "effect-test",
        version: 1,
        steps: [%{name: "write", action: "Test.Write", params: %{}}]
      })

    yaml = "name: effect-test\nversion: 1\nsteps: []\n"

    source = %{
      path: "effect-test.yaml",
      yaml: yaml,
      sha256: :crypto.hash(:sha256, yaml) |> Base.encode16(case: :lower)
    }

    assert {:ok, store} = Store.open(project.bedrock_path)
    assert :ok = Store.create_run(store, "effect-run", definition, %{}, source)
    assert :ok = Store.start_step(store, "effect-run", 0, hd(definition.steps), %{})

    context = %{
      effect_store: %{
        api: ReceiptFailureStore,
        store: store,
        run_id: "effect-run",
        step_position: 0
      }
    }

    reconcile = fn ->
      if File.exists?(marker), do: {:ok, %{path: marker}}, else: :not_applied
    end

    apply = fn ->
      Agent.update(counter, &(&1 + 1))
      File.write!(marker, "applied")
      {:ok, %{path: marker}}
    end

    assert {:error, {:effect_receipt_failed, :simulated_crash_gap}} =
             Effect.run(context, "write", "file.write", %{path: marker}, reconcile, apply)

    assert {:ok, %{path: ^marker}} =
             Effect.run(context, "write", "file.write", %{path: marker}, reconcile, apply)

    assert Agent.get(counter, & &1) == 1
    Store.flush(store)
  end

  test "flushes an external effect intent before applying it" do
    context = effect_context(%{owner: self(), flush_result: :ok})

    assert {:ok, %{commit: "abc123"}} =
             Effect.run(
               context,
               "land",
               "git.merge_ff_only",
               %{commit: "abc123"},
               fn -> :not_applied end,
               fn ->
                 send(self(), :external_effect_applied)
                 {:ok, %{commit: "abc123"}}
               end
             )

    assert_received {:intent, "git.merge_ff_only", %{commit: "abc123"}}
    assert_received :intent_flushed
    assert_received :external_effect_applied
    assert_received {:receipt, %{commit: "abc123"}}
  end

  test "does not apply an external effect when the intent cannot be flushed" do
    context = effect_context(%{owner: self(), flush_result: {:error, :disk_full}})

    assert {:error, {:effect_intent_flush_failed, "land", :disk_full}} =
             Effect.run(
               context,
               "land",
               "git.merge_ff_only",
               %{commit: "abc123"},
               fn -> :not_applied end,
               fn ->
                 send(self(), :external_effect_applied)
                 {:ok, %{commit: "abc123"}}
               end
             )

    assert_received {:intent, "git.merge_ff_only", %{commit: "abc123"}}
    assert_received :intent_flushed
    refute_received :external_effect_applied
  end

  test "keeps prior provider operation IDs as retry evidence" do
    root = temporary_directory()
    project = Hancho.Project.new(root)
    {store, definition} = started_store(project, "operation-run")

    assert :ok =
             Store.record_step_operation(
               store,
               "operation-run",
               0,
               "jido_harness.run",
               "harness-old",
               %{phase: "started"}
             )

    assert :ok =
             Store.record_step_operation(
               store,
               "operation-run",
               0,
               "jido_harness.run",
               "harness-new",
               %{phase: "started"}
             )

    assert {:ok,
            %{
              "id" => "harness-new",
              "history" => [
                %{
                  "id" => "harness-old",
                  "kind" => "jido_harness.run",
                  "metadata" => %{"phase" => "started"}
                }
              ]
            }} =
             Store.fetch_step_operation(store, "operation-run", 0, "jido_harness.run")

    assert definition.name == "effect-test"
    assert :ok = Store.flush(store)
  end

  defp effect_context(store) do
    %{
      effect_store: %{
        api: OrderedIntentStore,
        store: store,
        run_id: "effect-run",
        step_position: 0
      }
    }
  end

  defp started_store(project, run_id) do
    {:ok, definition} =
      Definition.new(%{
        name: "effect-test",
        version: 1,
        steps: [%{name: "write", action: "Test.Write", params: %{}}]
      })

    yaml = "name: effect-test\nversion: 1\nsteps: []\n"

    source = %{
      path: "effect-test.yaml",
      yaml: yaml,
      sha256: :crypto.hash(:sha256, yaml) |> Base.encode16(case: :lower)
    }

    {:ok, store} = Store.open(project.bedrock_path)
    :ok = Store.create_run(store, run_id, definition, %{}, source)
    :ok = Store.start_step(store, run_id, 0, hd(definition.steps), %{})
    {store, definition}
  end

  defp temporary_directory do
    path = Path.join(System.tmp_dir!(), "hancho-effect-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)

    on_exit(fn ->
      Hancho.State.Bedrock.reset()
      File.rm_rf!(path)
    end)

    path
  end
end
