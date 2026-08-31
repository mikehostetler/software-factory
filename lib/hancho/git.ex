defmodule Hancho.Git do
  @moduledoc """
  Hancho's interface to the Git command-line client.

  All Git commands use erlexec so Hancho can stop the command and its process
  group when a timeout occurs.
  """

  @type option ::
          {:binary, String.t()}
          | {:extra_config, [{String.t(), String.t()}]}
          | {:working_dir, String.t()}
          | {:timeout, pos_integer()}
          | {:untracked_files, :no | :normal | :all}

  @spec executable() :: {:ok, String.t()} | {:error, :not_found}
  def executable do
    case System.find_executable("git") do
      nil -> {:error, :not_found}
      path -> {:ok, path}
    end
  end

  @spec config([option()]) :: Git.Config.t()
  def config(options \\ []) do
    options
    |> Keyword.put(:runner, Hancho.Git.Runner)
    |> Git.Config.new()
  end

  @spec repository_root([option()]) :: {:ok, String.t()} | {:error, term()}
  def repository_root(options \\ []) do
    options
    |> config()
    |> then(&Git.Info.root(config: &1))
  rescue
    error -> {:error, {:exception, error}}
  end

  @spec status([option()]) :: {:ok, Git.Status.t()} | {:error, term()}
  def status(options \\ []) do
    {status_options, config_options} = Keyword.split(options, [:untracked_files])
    Git.status(Keyword.put(status_options, :config, config(config_options)))
  rescue
    error -> {:error, {:exception, error}}
  end

  @spec head([option()]) :: {:ok, String.t()} | {:error, term()}
  def head(options \\ []), do: Git.rev_parse(ref: "HEAD", config: config(options))

  @spec show(String.t(), [option()]) :: {:ok, Git.ShowResult.t()} | {:error, term()}
  def show(ref, options \\ []), do: Git.show(ref: ref, config: config(options))

  @spec diff([option() | {:ref, String.t()}]) :: {:ok, Git.Diff.t()} | {:error, term()}
  def diff(options \\ []) do
    {diff_options, config_options} = Keyword.split(options, [:ref])
    Git.diff(Keyword.put(diff_options, :config, config(config_options)))
  end

  @spec worktrees([option()]) :: {:ok, [Git.Worktree.t()]} | {:error, term()}
  def worktrees(options \\ []), do: Git.worktree(config: config(options))

  @spec tracked_files(String.t(), String.t(), [option()]) ::
          {:ok, [String.t()]} | {:error, term()}
  def tracked_files(repository, path, options \\ []) do
    options
    |> Keyword.put(:working_dir, repository)
    |> config()
    |> then(&Git.ls_files(paths: [path], config: &1))
  end

  @spec create_worktree(String.t(), String.t(), String.t(), [option()]) ::
          {:ok, :done} | {:error, term()}
  def create_worktree(repository, path, ref, options \\ []) do
    worktree_config = config(Keyword.put(options, :working_dir, repository))
    Git.worktree(add_path: path, add_branch: ref, detach: true, config: worktree_config)
  end

  @spec remove_worktree(String.t(), String.t(), [option()]) :: {:ok, :done} | {:error, term()}
  def remove_worktree(repository, path, options \\ []) do
    worktree_config = config(Keyword.put(options, :working_dir, repository))
    Git.worktree(remove_path: path, force: false, config: worktree_config)
  end

  @spec add_all(String.t(), [option()]) :: {:ok, :done} | {:error, term()}
  def add_all(repository, options \\ []) do
    Git.add(all: true, config: config(Keyword.put(options, :working_dir, repository)))
  end

  @spec commit(String.t(), String.t(), [option()]) ::
          {:ok, Git.CommitResult.t()} | {:error, term()}
  def commit(repository, message, options \\ []) do
    extra_config =
      options
      |> Keyword.get(:extra_config, [])
      |> Enum.reject(fn {key, _value} -> key == "commit.gpgsign" end)
      |> Kernel.++([{"commit.gpgsign", "false"}])

    commit_options =
      options
      |> Keyword.put(:working_dir, repository)
      |> Keyword.put(:extra_config, extra_config)

    Git.commit(message, config: config(commit_options))
  end

  @spec merge_ff_only(String.t(), String.t(), [option()]) ::
          {:ok, Git.MergeResult.t()} | {:ok, :done} | {:error, term()}
  def merge_ff_only(repository, commit, options \\ []) do
    Git.merge(commit,
      ff_only: true,
      config: config(Keyword.put(options, :working_dir, repository))
    )
  end
end
