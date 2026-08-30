defmodule Hancho.ModelDiscoveryCLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  defmodule ProjectAPI do
    def discover(cwd: cwd), do: {:ok, Hancho.Project.new(cwd)}
  end

  defmodule ModelsAPI do
    def discover(project, options) do
      send(self(), {:model_discovery, project.root, options[:smoke]})

      {:ok,
       %{
         "providers" => [
           %{
             "provider" => "codex",
             "authentication" => "authenticated",
             "cli" => %{"installed" => true, "path" => "/usr/bin/codex"},
             "model_discovery" => %{"status" => "reported", "models" => ["gpt-test"]},
             "models" => %{
               "cli_reported" => ["gpt-test"],
               "user_configured" => [],
               "smoke_accepted" => []
             },
             "smoke_tests" => [],
             "supported_reasoning_levels" => ["low", "high"]
           }
         ],
         "smoke_test_enabled" => options[:smoke],
         "source" => "repository_workflows"
       }}
    end

    def format(report), do: "Human model report for #{length(report["providers"])} provider"
  end

  test "prints clear human model discovery output" do
    output =
      capture_io(fn ->
        assert Hancho.CLI.run(["models"],
                 cwd: "/repo",
                 project_api: ProjectAPI,
                 models_api: ModelsAPI
               ) == 0
      end)

    assert output == "Human model report for 1 provider\n"
    assert_received {:model_discovery, "/repo", true}
  end

  test "prints JSON and supports disabling smoke tests" do
    output =
      capture_io(fn ->
        assert Hancho.CLI.run(["models", "discover", "--json", "--no-smoke"],
                 cwd: "/repo",
                 project_api: ProjectAPI,
                 models_api: ModelsAPI
               ) == 0
      end)

    assert Jason.decode!(output)["smoke_test_enabled"] == false
    assert_received {:model_discovery, "/repo", false}
  end
end
