defmodule Hancho.Workflow.QueueResult do
  @moduledoc "The terminal result of one foreground workflow queue."

  @schema Zoi.struct(
            __MODULE__,
            %{
              queue_id: Zoi.string() |> Zoi.min(1),
              workflow: Zoi.string() |> Zoi.min(1),
              status: Zoi.enum([:completed, :stopped]),
              completed_count: Zoi.integer() |> Zoi.min(0),
              total_count: Zoi.integer() |> Zoi.min(1),
              current_issue: Zoi.string() |> Zoi.nullish(),
              child_runs: Zoi.array(Zoi.string()),
              elapsed_ms: Zoi.integer() |> Zoi.min(0) |> Zoi.nullish() |> Zoi.default(nil),
              task_summaries: Zoi.array(Zoi.map()) |> Zoi.default([]),
              usage_summary: Zoi.map() |> Zoi.default(%{}),
              error: Zoi.any() |> Zoi.nullish(),
              forensic_report: Zoi.string() |> Zoi.nullish() |> Zoi.default(nil)
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attributes), do: Zoi.parse(@schema, attributes)
end
