defmodule Sandbox.GitWorktree do
  @moduledoc """
  Isolated Git worktree sandbox implementation.

  Uses Briefly to create and manage a temporary directory for each sandbox,
  allowing concurrent safe editing via Git worktrees. The specified Git ref
  (default "HEAD") is checked out into the new worktree to form the sandbox.
  """

  @behaviour Sandbox

  alias Git

  def prepare_sandbox(context, _opts) do
    with {:ok, tempdir} <- Briefly.create(directory: true),
         ref = context[:git_ref] || "HEAD",
         {:ok, _} <- Git.create_worktree(ref, tempdir) do
      {:ok, %{worktree: tempdir, ref: ref, temp_ref: tempdir}}
    else
      error -> error
    end
  end

  def sandbox_path(state), do: state.worktree

  def finalize_sandbox_commit(state) do
    # Show the git diff (between the sandbox HEAD and the ref)
    # We could add a thin wrapper in Git for this, but for now use System.cmd directly
    {diff, 0} =
      System.cmd("git", ["-C", state.worktree, "diff", "--no-color"],
        into: "",
        stderr_to_stdout: true
      )

    UI.say("\nDiff of your changes in the sandbox:\n\n#{diff}\n")

    if UI.confirm("Apply these changes?") do
      :ok
    else
      {:error, :rejected}
    end
  end

  def finalize_sandbox_discard(_state), do: :ok

  def cleanup_sandbox(state) do
    Git.remove_worktree(state.worktree)
    :ok
  end
end
