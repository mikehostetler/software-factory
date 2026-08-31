defmodule Hancho.MatrixRun.Report do
  @moduledoc "Writes and formats durable matrix comparison reports."

  @spec persist(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def persist(report, root) do
    json_path = Path.join(root, "report.json")
    markdown_path = Path.join(root, "comparison.md")
    report = put_in(report, ["artifacts"], %{"json" => json_path, "comparison" => markdown_path})

    with :ok <- File.mkdir_p(root),
         :ok <- File.chmod(root, 0o700),
         :ok <- atomic_write(json_path, Jason.encode_to_iodata!(report, pretty: true)),
         :ok <- atomic_write(markdown_path, markdown(report)) do
      {:ok, report}
    end
  end

  @spec human(map()) :: String.t()
  def human(report) do
    runs = report["runs"]
    comparison = report["comparison"]

    lines = [
      "Matrix run: #{report["matrix_run_id"]}",
      "Status: #{report["status"]}",
      "Baseline: #{report["baseline"]["head"]}",
      "Cells: #{length(runs)}; concurrency #{report["limits"]["concurrency"]}",
      "Elapsed: #{get_in(report, ["timing", "elapsed_ms"])} ms",
      "Results:"
    ]

    run_lines = Enum.map(runs, &human_run/1)

    comparison_lines =
      [
        "Comparison: #{comparison["status"]}; ranking #{comparison["ranking"]}",
        comparison["notice"]
      ] ++
        Enum.map(comparison["differences"], fn difference ->
          "- Difference in #{difference["field"]}: #{difference_value(difference)}"
        end) ++
        [
          "JSON report: #{get_in(report, ["artifacts", "json"])}",
          "Comparison report: #{get_in(report, ["artifacts", "comparison"])}"
        ]

    Enum.join(lines ++ run_lines ++ comparison_lines, "\n")
  end

  @spec markdown(map()) :: String.t()
  def markdown(report) do
    comparison = report["comparison"]

    runs =
      Enum.map_join(report["runs"], "\n", fn run ->
        model = run["requested_model"] || "provider default"
        effective = get_in(run, ["evidence", "effective_model", "value"]) || "not observed"
        tests = get_in(run, ["evidence", "tests", "status"])
        changes = get_in(run, ["evidence", "file_changes", "workspace"]) |> length()
        tokens = get_in(run, ["usage", "values", "total_tokens"]) || "not reported"
        cost = get_in(run, ["cost", "value_usd"]) || "not reported"

        "| #{run["cell_id"]} | #{run["provider"]} | #{model} | #{effective} | #{run["status"]} | #{get_in(run, ["timing", "elapsed_ms"])} | #{tests} | #{changes} | #{tokens} | #{cost} |"
      end)

    differences =
      case comparison["differences"] do
        [] -> "No differences were observed in the compared fields."
        values -> Enum.map_join(values, "\n", &"- **#{&1["field"]}:** #{difference_value(&1)}")
      end

    incomplete =
      case comparison["incomplete_reasons"] do
        [] -> "No missing comparison evidence was detected."
        values -> Enum.map_join(values, "\n", &"- #{&1}")
      end

    """
    # Hancho matrix comparison #{report["matrix_run_id"]}

    Status: **#{report["status"]}**

    Baseline: `#{report["baseline"]["head"]}`

    Comparison: **#{comparison["status"]}**

    Ranking: **#{comparison["ranking"]}**

    #{comparison["notice"]}

    ## Cells

    | Cell | Provider | Requested model | Effective model | Status | Time (ms) | Tests | Changed paths | Total tokens | Cost (USD) |
    | --- | --- | --- | --- | --- | ---: | --- | ---: | ---: | ---: |
    #{runs}

    ## Observed differences

    #{differences}

    ## Incomplete evidence

    #{incomplete}
    """
  end

  defp human_run(run) do
    requested = run["requested_model"] || "provider default"
    effective = get_in(run, ["evidence", "effective_model", "value"]) || "not observed"
    changed = get_in(run, ["evidence", "file_changes", "workspace"]) |> length()

    "- #{run["cell_id"]}: #{run["status"]}; #{run["provider"]}; requested #{requested}; effective #{effective}; #{changed} changed paths; #{get_in(run, ["timing", "elapsed_ms"])} ms"
  end

  defp difference_value(%{"values" => values}), do: inspect(values)
  defp difference_value(%{"groups" => groups}), do: inspect(groups)

  defp atomic_write(path, contents) do
    temporary = path <> ".tmp-" <> nonce()

    with :ok <- File.write(temporary, contents, [:binary, :sync]),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} = error ->
        _result = File.rm(temporary)
        if reason == :exdev, do: {:error, {:atomic_write_not_supported, path}}, else: error
    end
  end

  defp nonce, do: :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
end
