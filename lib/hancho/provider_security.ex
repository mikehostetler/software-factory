defmodule Hancho.ProviderSecurity do
  @moduledoc "Builds provider controls that deny common credential file reads."

  @credential_paths [
    "**/.config/gh/hosts.yml",
    "**/.ssh/id_*",
    "**/.ssh/*_key",
    "**/.aws/credentials",
    "**/.aws/config",
    "**/.config/gcloud/**",
    "**/.azure/**",
    "**/.kube/config",
    "**/.docker/config.json",
    "**/.netrc",
    "**/.git-credentials",
    "**/.npmrc",
    "**/.pypirc",
    "**/.env",
    "**/.env.*"
  ]

  @spec options(atom()) :: map()
  def options(:grok) do
    %{
      provider_options: %{deny_rules: permission_rules()},
      evidence: %{
        profile: "grok_deny_rules",
        enforced: true,
        rule_count: length(permission_rules())
      }
    }
  end

  def options(provider) when provider in [:claude, :zai] do
    settings = Jason.encode!(%{"permissions" => %{"deny" => permission_rules()}})

    %{
      provider_options: %{settings: settings},
      evidence: %{
        profile: "claude_permission_rules",
        enforced: true,
        rule_count: length(permission_rules())
      }
    }
  end

  def options(_provider) do
    %{
      provider_options: %{},
      evidence: %{
        profile: "workspace_sandbox_only",
        enforced: false,
        limitation: "The selected Jido.Harness adapter has no credential path deny option."
      }
    }
  end

  @spec permission_rules() :: [String.t()]
  def permission_rules do
    read_rules = Enum.map(@credential_paths, &"Read(#{&1})")
    grep_rules = Enum.map(@credential_paths, &"Grep(#{&1})")
    shell_rules = Enum.map(@credential_paths, &"Bash(*#{shell_fragment(&1)}*)")
    read_rules ++ grep_rules ++ shell_rules
  end

  defp shell_fragment(path) do
    path
    |> String.trim_leading("**/")
    |> String.replace("**", "*")
  end
end
