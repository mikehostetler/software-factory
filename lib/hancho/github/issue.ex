defmodule Hancho.GitHub.Issue do
  @moduledoc "Validated GitHub demand data returned by the GitHub adapter."

  @schema Zoi.struct(
            __MODULE__,
            %{
              repository: Zoi.string() |> Zoi.min(3),
              node_id: Zoi.string() |> Zoi.min(1),
              number: Zoi.integer() |> Zoi.min(1),
              title: Zoi.string() |> Zoi.min(1),
              url: Zoi.string() |> Zoi.min(1),
              state: Zoi.string() |> Zoi.min(1),
              body: Zoi.string() |> Zoi.nullish() |> Zoi.default(nil),
              updated_at: Zoi.string() |> Zoi.nullish() |> Zoi.default(nil),
              parent_node_id: Zoi.string() |> Zoi.nullish() |> Zoi.default(nil),
              comments: Zoi.array(Zoi.string()) |> Zoi.default([]),
              child_count: Zoi.integer() |> Zoi.min(0) |> Zoi.default(0)
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
