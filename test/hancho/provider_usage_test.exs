defmodule Hancho.ProviderUsageTest do
  use ExUnit.Case, async: true

  alias Hancho.ProviderUsage

  test "marks Grok usage as provider-cumulative and does not add it" do
    grok =
      ProviderUsage.normalize(:grok, %{
        "input_tokens" => 80_000,
        "output_tokens" => 4_000,
        "total_tokens" => 84_000
      })
      |> ProviderUsage.to_map()

    assert grok["scope"] == "provider_cumulative"
    refute grok["additive"]

    summary = ProviderUsage.summarize([grok])
    assert summary["status"] == "non_additive"
    assert summary["values"] == %{}
    assert summary["excluded_task_count"] == 1
  end

  test "adds only normalized run-scoped task usage" do
    first =
      ProviderUsage.normalize(:codex, %{
        "input_tokens" => 10,
        "output_tokens" => 2,
        "total_tokens" => 12
      })
      |> ProviderUsage.to_map()

    second =
      ProviderUsage.normalize(:claude, %{
        "input_tokens" => 4,
        "output_tokens" => 1,
        "total_tokens" => 5
      })
      |> ProviderUsage.to_map()

    summary = ProviderUsage.summarize([first, second])
    assert summary["status"] == "available"

    assert summary["values"] == %{
             "input_tokens" => 14,
             "output_tokens" => 3,
             "total_tokens" => 17
           }
  end

  test "labels missing usage as unavailable" do
    usage = ProviderUsage.normalize(:codex, %{}) |> ProviderUsage.to_map()
    assert usage["status"] == "unavailable"
    assert usage["scope"] == "unavailable"
  end
end
