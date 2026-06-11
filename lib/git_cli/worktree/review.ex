defmodule GitCli.Worktree.Review do
  @moduledoc """
  Facade for the shared interactive flow for reviewing, merging, and
  cleaning up a fnord-managed worktree. Used by both `Cmd.Ask`
  (post-completion) and `Cmd.Worktrees merge`.

  Includes pre-merge and post-merge validation gates that run the project's
  configured validation rules against the worktree (before merge) and the
  main checkout (after merge). Post-merge validation failure triggers an
  automatic revert, while merge command failures are returned to the caller.

  Public functions dispatch through `impl/0`, resolved via the
  `:git_review` Globals key and defaulting to
  `GitCli.Worktree.Review.Default`. Tests do NOT point this key at a
  mock by default; tests that script the review/merge outcome opt in
  per test (see `Fnord.TestCase.mock_git_review/0`).
  """

  @type worktree_info :: %{
          path: String.t(),
          branch: String.t(),
          base_branch: String.t()
        }

  @type merge_range :: {String.t(), String.t()} | nil

  @type review_result ::
          :ok
          | {:cleaned_up, merge_range(), :interactive | :auto}
          | {:validation_failed, :pre_merge | :post_merge, String.t()}
          | {:merge_failed, String.t()}

  @callback interactive_review(String.t(), worktree_info(), keyword()) :: review_result()
  @callback auto_merge(String.t(), worktree_info(), keyword()) :: review_result()
  @callback colorize_diff(String.t()) :: Owl.Data.t()

  @doc """
  Walks the user through inspecting the diff, merging, and optionally deleting
  the worktree and its local branch. Runs validation before and after merge.
  """
  @spec interactive_review(String.t(), worktree_info(), keyword()) :: review_result()
  def interactive_review(root, meta, opts \\ []),
    do: impl().interactive_review(root, meta, opts)

  @doc """
  Merges worktree changes and cleans up without prompting. Runs validation
  before and after merge. Pre-merge validation failure blocks the merge.
  """
  @spec auto_merge(String.t(), worktree_info(), keyword()) :: review_result()
  def auto_merge(root, meta, opts \\ []),
    do: impl().auto_merge(root, meta, opts)

  @doc "Colorizes a unified diff string for terminal display."
  @spec colorize_diff(String.t()) :: Owl.Data.t()
  def colorize_diff(diff), do: impl().colorize_diff(diff)

  @spec impl() :: module
  def impl() do
    Services.Globals.get_env(:fnord, :git_review) || GitCli.Worktree.Review.Default
  end
end
