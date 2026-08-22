defmodule Hancho.Demand.Snapshot do
  @moduledoc "A durable snapshot of the demand text used by one workflow run."

  alias Hancho.Beadwork.Issue, as: BeadworkIssue
  alias Hancho.GitHub.Issue, as: GitHubIssue

  @schema Zoi.struct(
            __MODULE__,
            %{
              source: Zoi.enum(["github", "beadwork"]),
              repository: Zoi.string() |> Zoi.nullish() |> Zoi.default(nil),
              url: Zoi.string() |> Zoi.nullish() |> Zoi.default(nil),
              node_id: Zoi.string() |> Zoi.nullish() |> Zoi.default(nil),
              title: Zoi.string() |> Zoi.min(1),
              body: Zoi.string() |> Zoi.default(""),
              updated_at: Zoi.string() |> Zoi.nullish() |> Zoi.default(nil),
              content_sha256: Zoi.string() |> Zoi.min(64)
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec from_github(GitHubIssue.t()) :: t()
  def from_github(%GitHubIssue{} = issue) do
    new!(%{
      source: "github",
      repository: issue.repository,
      url: issue.url,
      node_id: issue.node_id,
      title: issue.title,
      body: issue.body || "",
      updated_at: issue.updated_at
    })
  end

  @spec from_beadwork(BeadworkIssue.t()) :: t()
  def from_beadwork(%BeadworkIssue{} = issue) do
    new!(%{
      source: "beadwork",
      repository: nil,
      url: nil,
      node_id: nil,
      title: issue.title || issue.id,
      body: issue.description,
      updated_at: nil
    })
  end

  @spec new!(map()) :: t()
  def new!(attributes) do
    values = Map.new(attributes)
    Zoi.parse!(@schema, Map.put(values, :content_sha256, content_hash(values)))
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = snapshot) do
    snapshot
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp content_hash(values) do
    [
      value(values, :source),
      value(values, :repository),
      value(values, :url),
      value(values, :node_id),
      value(values, :title),
      value(values, :body) || "",
      value(values, :updated_at)
    ]
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp value(values, key), do: Map.get(values, key, Map.get(values, Atom.to_string(key)))
end
