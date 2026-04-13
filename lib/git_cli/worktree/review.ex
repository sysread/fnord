defmodule GitCli.Worktree.Review do
  @moduledoc """
  Shared interactive flow for reviewing, merging, and cleaning up a
  fnord-managed worktree. Used by both `Cmd.Ask` (post-completion) and
  `Cmd.Worktrees merge`.

  Includes pre-merge and post-merge validation gates that run the project's
  configured validation rules against the worktree (before merge) and the
  main checkout (after merge). Post-merge validation failure triggers an
  automatic revert, while merge command failures are returned to the caller.
  """

  @type worktree_info :: %{
          path: String.t(),
          branch: String.t(),
          base_branch: String.t()
        }

  @type review_result ::
          :ok
          | {:cleaned_up, String.t() | nil, :interactive | :auto}
          | {:validation_failed, :pre_merge | :post_merge, String.t()}
          | {:merge_failed, String.t()}

  @spec interactive_review(String.t(), worktree_info(), keyword()) :: review_result()
  @doc """
  Walks the user through inspecting the diff, merging, and optionally deleting
  the worktree and its local branch. Runs validation before and after merge.
  """
  def interactive_review(root, meta, opts \\ [])

  def interactive_review(root, %{path: path, branch: branch, base_branch: base_branch}, opts) do
    unless UI.is_tty?() do
      throw(:skip)
    end

    print_header()
    log_ignored_files(opts)
    target = GitCli.Worktree.current_branch(root) || "HEAD"

    unless UI.confirm(wt_prompt("Inspect changes from worktree branch #{branch}?")) do
      throw(:skip)
    end

    show_diff(root, branch, base_branch)

    unless UI.confirm(wt_prompt("Merge #{branch} into #{target}?")) do
      throw(:skip)
    end

    # Pre-merge validation: run in the worktree
    case run_validation(path, "Pre-merge") do
      :ok ->
        :ok

      {:failed, summary} ->
        UI.error("Pre-merge validation failed")
        UI.say(summary)

        unless UI.confirm(wt_prompt("Merge anyway despite validation failure?")) do
          throw({:validation_failed, :pre_merge, summary})
        end
    end

    case do_merge_with_post_validation(root, path, branch, target) do
      {:ok, sha} ->
        if maybe_cleanup(root, path, branch) do
          throw({:cleaned_up, sha, :interactive})
        end

        :ok

      {:validation_failed, :post_merge, _summary} = failure ->
        throw(failure)

      {:merge_failed, _reason} = failure ->
        throw(failure)
    end
  catch
    :throw, :skip -> :ok
    :throw, {:cleaned_up, sha, mode} -> {:cleaned_up, sha, mode}
    :throw, {:validation_failed, _, _} = failure -> failure
    :throw, {:merge_failed, _reason} = failure -> failure
  end

  @spec auto_merge(String.t(), worktree_info(), keyword()) :: review_result()
  @doc """
  Merges worktree changes and cleans up without prompting. Runs validation
  before and after merge. Pre-merge validation failure blocks the merge.
  """
  def auto_merge(root, meta, opts \\ [])

  def auto_merge(root, %{path: path, branch: branch, base_branch: base_branch}, opts) do
    print_header()
    log_ignored_files(opts)
    target = GitCli.Worktree.current_branch(root) || "HEAD"
    UI.info("Auto-merge", "#{branch} into #{target}")
    show_diff(root, branch, base_branch)

    # Pre-merge validation: block on failure
    case run_validation(path, "Pre-merge") do
      :ok -> :ok
      {:failed, summary} -> throw({:validation_failed, :pre_merge, summary})
    end

    case do_merge_with_post_validation(root, path, branch, target) do
      {:ok, sha} ->
        cleanup(root, path, branch)
        {:cleaned_up, sha, :auto}

      {:validation_failed, :post_merge, _summary} = failure ->
        throw(failure)

      {:merge_failed, _reason} = failure ->
        throw(failure)
    end
  catch
    :throw, {:validation_failed, _, _} = failure -> failure
    :throw, {:merge_failed, _reason} = failure -> failure
  end

  # Merges the worktree branch into root, then runs post-merge validation.
  # If the merge command fails, returns the failure to the caller. If
  # post-merge validation fails, resets HEAD to the pre-merge state. A hard
  # reset is necessary because ff merges can advance HEAD by multiple commits,
  # and `git revert HEAD` would only undo the last one.
  defp do_merge_with_post_validation(root, path, branch, target) do
    pre_merge_sha = GitCli.Worktree.head_sha_full(root)

    case GitCli.Worktree.merge(root, path) do
      {:ok, _} ->
        sha = GitCli.Worktree.head_sha(root)
        UI.info("Merged", "#{branch} into #{target}")

        case run_validation(root, "Post-merge") do
          :ok ->
            {:ok, sha}

          {:failed, summary} ->
            UI.error("Post-merge validation failed; reverting merge")

            case GitCli.Worktree.reset_hard(root, pre_merge_sha) do
              {:ok, :ok} -> UI.info("Reset to pre-merge state")
              {:error, reason} -> UI.warn("Reset failed: #{reason}")
            end

            {:validation_failed, :post_merge, summary}
        end

      {:error, reason} ->
        UI.error("Merge failed: #{reason}")
        {:merge_failed, reason}
    end
  end

  # Runs validation rules against the given root and returns :ok or {:failed, summary}.
  # Returns :ok when there are no rules, no matches, or no changes.
  defp run_validation(root, label) do
    with {:ok, project} <- Store.get_project() do
      UI.info(label, "running validation in #{root}")
      result = Validation.Rules.run(project.name, root)

      case result do
        {:ok, :no_changes} ->
          :ok

        {:ok, :no_rules, _, _} ->
          :ok

        {:ok, :no_matches, _, _} ->
          :ok

        {:ok, _results, _fingerprint} ->
          UI.info(label, "validation passed")
          :ok

        {:error, :discovery_failed} ->
          UI.warn("#{label}: could not determine changed files")
          :ok

        {:error, _, _} ->
          {:failed, Validation.Rules.summarize(result)}
      end
    else
      _ -> :ok
    end
  end

  defp log_ignored_files(opts) do
    case Keyword.get(opts, :ignored_files, []) do
      [] -> :ok
      files -> Enum.each(files, &UI.info("Copied ignored file", &1))
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
