defmodule Cmd.WorktreeLifecycle do
  @moduledoc """
  Shared worktree lifecycle helpers used by `Cmd.Worktrees`, `Cmd.Conversations`,
  and `Cmd.Ask` for managing worktree cleanup, deletion prompts, and conversation
  metadata updates.
  """

  @spec warn_if_unmerged(String.t(), map()) :: :ok | {:error, :cancelled}
  @doc """
  Warns the user if the worktree branch has unmerged commits relative to its
  base branch. Returns `:ok` to continue or `{:error, :cancelled}` if the
  user declines to proceed.
  """
  def warn_if_unmerged(root, %{branch: branch, base_branch: base_branch})
      when is_binary(branch) and is_binary(base_branch) do
    case GitCli.Worktree.diff_against_base(root, branch, base_branch) do
      {:ok, diff} when byte_size(diff) > 0 ->
        UI.warn("Branch #{branch} has commits that have NOT been merged into #{base_branch}.")

        if UI.confirm("Proceed with deletion anyway?") do
          :ok
        else
          {:error, :cancelled}
        end

      _ ->
        :ok
    end
  end

  def warn_if_unmerged(_root, _meta), do: :ok

  @spec delete_worktree(String.t(), String.t()) :: {:ok, :ok} | {:error, atom()}
  @doc """
  Attempts a clean worktree removal. If the worktree has uncommitted changes,
  warns the user and asks for confirmation before force-deleting.
  """
  def delete_worktree(root, path) do
    case GitCli.Worktree.delete(root, path) do
      {:ok, :ok} ->
        {:ok, :ok}

      {:error, _} when is_binary(path) ->
        if GitCli.Worktree.has_uncommitted_changes?(path) do
          UI.warn("Worktree at #{path} has uncommitted changes that will be lost.")

          if UI.confirm("Force delete anyway?") do
            GitCli.Worktree.force_delete(root, path)
          else
            {:error, :cancelled}
          end
        else
          {:error, :git_failed}
        end
    end
  end

  @spec clear_worktree_from_conversation(String.t()) :: :ok
  @doc """
  Removes worktree metadata from a conversation and appends a system message
  so the LLM knows the worktree is gone if the conversation is continued.
  """
  def clear_worktree_from_conversation(conv_id) do
    conv = Store.Project.Conversation.new(conv_id)

    with {:ok, data} <- Store.Project.Conversation.read(conv) do
      updated_metadata = Map.delete(data.metadata, :worktree)

      worktree_deleted_msg =
        AI.Util.system_msg("""
        The worktree previously associated with this conversation has been deleted.
        You will need to verify whether your changes were merged before building on
        top of them. Keep this in mind when responding to the user.
        """)

      updated_messages = data.messages ++ [worktree_deleted_msg]

      Store.Project.Conversation.write(conv, %{
        data
        | metadata: updated_metadata,
          messages: updated_messages
      })
    end

    :ok
  end

  @spec cleanup_worktree_for_conversation(Store.Project.Conversation.t()) :: :ok
  @doc """
  Checks whether a conversation has an associated worktree on disk and offers
  to delete it. Used during conversation deletion to avoid orphaned worktrees.
  """
  def cleanup_worktree_for_conversation(conversation) do
    with {:ok, data} <- safe_read_conversation(conversation),
         meta <- extract_worktree_meta(data.metadata),
         true <- is_map(meta) and is_binary(Map.get(meta, :path)),
         true <- File.dir?(meta.path),
         {:ok, root} <- GitCli.Worktree.project_root() do
      UI.info("Conversation has worktree", meta.path)

      status =
        cond do
          GitCli.Worktree.has_uncommitted_changes?(meta.path) -> :dirty
          has_unmerged_commits?(root, meta) -> :unmerged
          true -> :clean
        end

      case status do
        :dirty ->
          UI.warn("Worktree has uncommitted changes.")
          prompt_worktree_deletion(root, meta)

        :unmerged ->
          UI.warn("Worktree branch has unmerged commits.")
          prompt_worktree_deletion(root, meta)

        :clean ->
          prompt_worktree_deletion(root, meta)
      end
    else
      _ -> :ok
    end
  end

  defp prompt_worktree_deletion(root, meta) do
    if UI.confirm("Delete worktree and local branch?") do
      case GitCli.Worktree.force_delete(root, meta.path) do
        {:ok, :ok} -> UI.info("Deleted worktree", meta.path)
        {:error, reason} -> UI.warn("Failed to delete worktree: #{reason}")
      end

      if is_binary(meta.branch) do
        case GitCli.Worktree.delete_branch(root, meta.branch) do
          {:ok, :ok} -> UI.info("Deleted branch", meta.branch)
          {:error, reason} -> UI.warn("Failed to delete branch: #{reason}")
        end
      end
    end

    :ok
  end

  defp has_unmerged_commits?(root, %{branch: branch, base_branch: base_branch})
       when is_binary(branch) and is_binary(base_branch) do
    case GitCli.Worktree.diff_against_base(root, branch, base_branch) do
      {:ok, diff} when byte_size(diff) > 0 -> true
      _ -> false
    end
  end

  defp has_unmerged_commits?(_root, _meta), do: false

  # Reads conversation data, suppressing errors from corrupt or minimal files
  # that may call UI functions not available in all contexts.
  defp safe_read_conversation(conversation) do
    Store.Project.Conversation.read(conversation)
  rescue
    _ -> {:error, :unreadable}
  end

  defp extract_worktree_meta(metadata) when is_map(metadata) do
    metadata
    |> GitCli.Worktree.normalize_worktree_meta_in_parent()
    |> Map.get(:worktree)
  end
end
