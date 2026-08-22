defmodule Hancho.WorktreeSetup do
  @moduledoc "Prepares writable Mix paths in one isolated worktree."

  @spec prepare(String.t()) :: {:ok, map()} | {:error, term()}
  def prepare(worktree) do
    worktree = Path.expand(worktree)
    deps = Path.join(worktree, "deps")
    build = Path.join(worktree, "_build")

    with :ok <- directory(worktree),
         :ok <- writable_directory(deps),
         :ok <- writable_directory(build) do
      {:ok,
       %{
         env: %{"MIX_DEPS_PATH" => deps, "MIX_BUILD_PATH" => build},
         deps_path: deps,
         build_path: build
       }}
    end
  end

  defp directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, %File.Stat{type: :symlink}} -> {:error, :worktree_is_symlink}
      {:ok, _stat} -> {:error, :worktree_is_not_directory}
      {:error, reason} -> {:error, {:worktree_unavailable, reason}}
    end
  end

  defp writable_directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} ->
        {:error, {:mix_path_is_symlink, Path.basename(path)}}

      {:ok, %File.Stat{type: :directory}} ->
        writable(path)

      {:ok, _stat} ->
        {:error, {:mix_path_is_not_directory, Path.basename(path)}}

      {:error, :enoent} ->
        with :ok <- File.mkdir(path), do: writable(path)

      {:error, reason} ->
        {:error, {:mix_path_unavailable, Path.basename(path), reason}}
    end
  end

  defp writable(path) do
    probe = Path.join(path, ".hancho-write-probe-#{nonce()}")

    case File.open(probe, [:write, :exclusive]) do
      {:ok, device} ->
        File.close(device)
        File.rm(probe)

      {:error, reason} ->
        {:error, {:mix_path_not_writable, Path.basename(path), reason}}
    end
  end

  defp nonce, do: :crypto.strong_rand_bytes(10) |> Base.url_encode64(padding: false)
end
