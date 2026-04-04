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

  @spec interactive_review(String.t(), worktree_info()) :: :ok | :cleaned_up
  @doc """
  Walks the user through inspecting the diff, merging, and optionally deleting
  the worktree and its local branch. Returns `:cleaned_up` when the worktree
  was deleted so callers can update conversation metadata. Silently returns
  `:ok` when running non-interactively or the user declines.
  """
  def interactive_review(root, %{path: path, branch: branch, base_branch: base_branch}) do
    unless UI.is_tty?() do
      throw(:skip)
    end

    print_header()
    target = GitCli.Worktree.current_branch(root) || "HEAD"

    unless UI.confirm(wt_prompt("Inspect changes from worktree branch #{branch}?")) do
      throw(:skip)
    end

    show_diff(root, branch, base_branch)

    unless UI.confirm(wt_prompt("Merge #{branch} into #{target}?")) do
      throw(:skip)
    end

    case GitCli.Worktree.merge(root, path) do
      {:ok, _} ->
        UI.info("Merged", "#{branch} into #{target}")

        if maybe_cleanup(root, path, branch) do
          throw(:cleaned_up)
        end

      {:error, reason} ->
        UI.error("Merge failed: #{reason}")
    end

    :ok
  catch
    :throw, :skip -> :ok
    :throw, :cleaned_up -> :cleaned_up
  end

  @spec auto_merge(String.t(), worktree_info()) :: :ok | :cleaned_up
  @doc """
  Merges worktree changes and cleans up without prompting (cowboy mode).
  Shows the diff for the record but doesn't ask for confirmation.
  """
  def auto_merge(root, %{path: path, branch: branch, base_branch: base_branch}) do
    print_header()
    target = GitCli.Worktree.current_branch(root) || "HEAD"
    UI.info("Cowboy mode", "auto-merging #{branch} into #{target}")
    show_diff(root, branch, base_branch)

    case GitCli.Worktree.merge(root, path) do
      {:ok, _} ->
        UI.info("Merged", "#{branch} into #{target}")
        cleanup(root, path, branch)
        :cleaned_up

      {:error, reason} ->
        UI.error("Merge failed: #{reason}")
        :ok
    end
  end

  defp print_header do
    header =
      IO.ANSI.format(
        [:cyan_background, :black, :bright, " ◆ Worktree Review ◆ ", :reset],
        true
      )

    separator =
      IO.ANSI.format(
        [:cyan, String.duplicate("─", 60), :reset],
        true
      )

    IO.puts(:stderr, "\n#{separator}\n#{header}\n#{separator}\n")
    UI.Tee.write(["\n", separator, "\n", header, "\n", separator, "\n\n"])
  end

  # Formats a worktree review prompt with color so it stands out from
  # the surrounding log output.
  defp wt_prompt(msg) do
    IO.ANSI.format([:bright, :cyan, "◆ ", :reset, :bright, msg, :reset], true)
    |> IO.chardata_to_string()
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

  # Returns true if the worktree was deleted.
  defp maybe_cleanup(root, path, branch) do
    if UI.confirm(wt_prompt("Delete worktree and local branch #{branch}?")) do
      cleanup(root, path, branch)
      true
    else
      false
    end
  end

  defp cleanup(root, path, branch) do
    case GitCli.Worktree.force_delete(root, path) do
      {:ok, _} -> UI.info("Deleted worktree", path)
      {:error, reason} -> UI.warn("Failed to delete worktree: #{reason}")
    end

    case GitCli.Worktree.delete_branch(root, branch) do
      {:ok, _} ->
        UI.info("Deleted branch", branch)

      {:error, _} ->
        case GitCli.Worktree.force_delete_branch(root, branch) do
          {:ok, _} -> UI.info("Force-deleted branch", branch)
          {:error, reason} -> UI.warn("Failed to delete branch: #{reason}")
        end
    end
  end

  @doc "Colorizes a unified diff string for terminal display."
  def colorize_diff(diff) do
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
