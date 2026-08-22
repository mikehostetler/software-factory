defmodule Hancho.Actions.ValidateScope do
  @moduledoc "Checks implementation paths against the authoritative demand scope."

  use Jido.Action,
    name: "hancho_validate_scope",
    description: "Rejects implementation changes outside the ticket scope",
    schema:
      Zoi.object(%{
        worktree_path: Zoi.string() |> Zoi.min(1),
        demand: Zoi.map() |> Zoi.optional(),
        issue: Zoi.map() |> Zoi.optional()
      })

  alias Hancho.Actions.Context

  @section ~r/(?:^|\n)## Allowed Scope\s*\n(?<body>.*?)(?=\n## |\z)/s

  @impl true
  def run(params, context) do
    git = Context.service(context, :git, Hancho.Git)
    description = scope_description(params)

    with {:ok, allowed} <- allowed_scope(description),
         {:ok, status} <-
           git.status(working_dir: params.worktree_path, untracked_files: :all) do
      changed = status.entries |> Enum.map(& &1.path) |> Enum.uniq() |> Enum.sort()
      validate(changed, allowed)
    end
  end

  defp scope_description(%{demand: demand}) when is_map(demand),
    do: demand["body"] || demand[:body] || ""

  defp scope_description(%{issue: issue}) when is_map(issue),
    do: issue["description"] || issue[:description] || ""

  defp scope_description(_params), do: ""

  defp allowed_scope(description) do
    case Regex.named_captures(@section, description) do
      nil ->
        {:ok, :not_configured}

      %{"body" => body} ->
        paths =
          body
          |> String.split("\n")
          |> Enum.flat_map(&scope_line/1)

        cond do
          paths == [] -> {:error, "The Allowed Scope section does not contain paths."}
          Enum.all?(paths, &safe_scope?/1) -> {:ok, paths}
          true -> {:error, "The Allowed Scope section contains an unsafe path."}
        end
    end
  end

  defp scope_line(line) do
    case Regex.run(~r/^\s*-\s+`([^`]+)`\s*$/, line) do
      [_, path] -> [normalize_scope(path)]
      nil -> []
    end
  end

  defp normalize_scope("./" <> path), do: normalize_scope(path)
  defp normalize_scope(path), do: String.trim(path)

  defp safe_scope?(path) do
    path != "" and Path.type(path) == :relative and
      not Enum.member?(Path.split(path), "..")
  end

  defp validate(changed, :not_configured) do
    {:ok, %{status: "not_configured", allowed_scope: [], changed_paths: changed}}
  end

  defp validate(changed, allowed) do
    unexpected = Enum.reject(changed, &allowed?(&1, allowed))

    if unexpected == [] do
      {:ok, %{status: "checked", allowed_scope: allowed, changed_paths: changed}}
    else
      {:error,
       %{
         code: "changes_outside_allowed_scope",
         allowed_scope: allowed,
         unexpected_paths: unexpected
       }}
    end
  end

  defp allowed?(path, allowed) do
    Enum.any?(allowed, fn scope ->
      if String.ends_with?(scope, "/") do
        String.starts_with?(path, scope)
      else
        path == scope
      end
    end)
  end
end
