defmodule GitCli.Worktree.Review do
  @moduledoc """
  Shared interactive flow for reviewing, merging, and cleaning up a
  fnord-managed worktree. Used by both `Cmd.Ask` (post-completion) and
  `Cmd.Worktrees merge`.
  """

  @type worktree_info :: %{
          path: String.t(),
          branch: String.t(),
          base_branch: String.t()
        }

  @spec interactive_review(String.t(), worktree_info()) :: :ok
  @doc """
  Walks the user through inspecting the diff, merging, and optionally deleting
  the worktree and its local branch. Silently returns `:ok` when running
  non-interactively.
  """
  def interactive_review(root, %{path: path, branch: branch, base_branch: base_branch}) do
    unless UI.is_tty?() do
      throw(:skip)
    end

    target = GitCli.Worktree.current_branch(root) || "HEAD"

    unless UI.confirm("Inspect changes from worktree branch #{branch}?") do
      throw(:skip)
    end

    show_diff(root, branch, base_branch)

    unless UI.confirm("Merge #{branch} into #{target}?") do
      throw(:skip)
    end

    case GitCli.Worktree.merge(root, path) do
      {:ok, _} ->
        UI.info("Merged", "#{branch} into #{target}")
        maybe_cleanup(root, path, branch)

      {:error, reason} ->
        UI.error("Merge failed: #{reason}")
    end

    :ok
  catch
    :throw, :skip -> :ok
  end

  defp show_diff(root, branch, base_branch) do
    case GitCli.Worktree.diff_against_base(root, branch, base_branch) do
      {:ok, diff} when byte_size(diff) > 0 ->
        diff
        |> colorize_diff()
        |> UI.puts()

      {:ok, _} ->
        UI.info("Diff", "No changes between #{base_branch} and #{branch}")

      {:error, reason} ->
        UI.warn("Could not generate diff: #{reason}")
    end
  end

  defp maybe_cleanup(root, path, branch) do
    if UI.confirm("Delete worktree and local branch #{branch}?") do
      case GitCli.Worktree.delete(root, path) do
        {:ok, _} -> UI.info("Deleted worktree", path)
        {:error, reason} -> UI.warn("Failed to delete worktree: #{reason}")
      end

      case GitCli.Worktree.delete_branch(root, branch) do
        {:ok, _} -> UI.info("Deleted branch", branch)
        {:error, reason} -> UI.warn("Failed to delete branch: #{reason}")
      end
    end
  end

  defp colorize_diff(diff) do
    diff
    |> String.split("\n")
    |> Enum.map(fn line ->
      cond do
        String.starts_with?(line, "+") -> Owl.Data.tag(line <> "\n", [:white, :green_background])
        String.starts_with?(line, "-") -> Owl.Data.tag(line <> "\n", [:white, :red_background])
        true -> line <> "\n"
      end
    end)
  end
end
