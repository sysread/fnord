defmodule Cmd.Worktrees do
  @behaviour Cmd

  @impl Cmd
  def requires_project?(), do: true

  @impl Cmd
  def spec do
    [
      worktrees: [
        name: "worktrees",
        about: "Manage git worktrees for the current project",
        options: [
          project: Cmd.project_arg()
        ],
        subcommands: [
          list: [
            name: "list",
            about: "List worktrees with branch, merge status, and size"
          ],
          create: [
            name: "create",
            about: "Create a new conversation-scoped worktree",
            options: [
              conversation: [
                value_name: "CONVERSATION_ID",
                long: "--conversation",
                short: "-c",
                help: "Conversation id for worktree naming",
                parser: :string,
                required: true
              ],
              branch: [
                value_name: "BRANCH",
                long: "--branch",
                short: "-b",
                help: "Branch name (default: auto-generated)",
                parser: :string,
                required: false
              ]
            ]
          ],
          delete: [
            name: "delete",
            about: "Remove a conversation worktree",
            options: [
              conversation: [
                value_name: "CONVERSATION_ID",
                long: "--conversation",
                short: "-c",
                help: "Conversation id whose worktree to remove",
                parser: :string,
                required: true
              ]
            ]
          ],
          merge: [
            name: "merge",
            about: "Review, merge, and optionally clean up a conversation worktree",
            options: [
              conversation: [
                value_name: "CONVERSATION_ID",
                long: "--conversation",
                short: "-c",
                help: "Conversation id whose worktree to merge",
                parser: :string,
                required: true
              ]
            ]
          ]
        ]
      ]
    ]
  end

  @impl Cmd
  def run(_opts, [:list], _unknown) do
    with {:ok, project} <- Store.get_project(),
         {:ok, root} <- GitCli.Worktree.project_root(),
         {:ok, entries} <- GitCli.Worktree.list(root) do
      managed =
        Enum.filter(entries, fn entry ->
          GitCli.Worktree.fnord_managed?(project.name, entry.path)
        end)

      if managed == [] do
        UI.info("No fnord-managed worktrees found")
      else
        managed
        |> Enum.map(fn entry ->
          %{
            "Conversation" => Path.basename(entry.path),
            "Branch" => entry.branch || "-",
            "Status" => format_merge_status(entry.merge_status),
            "Size" => format_size(entry.size)
          }
        end)
        |> Owl.Table.new(
          padding_x: 1,
          sort_columns: fn a, b -> column_order(a) <= column_order(b) end
        )
        |> UI.puts()
      end

      :ok
    else
      {:error, :not_a_repo} ->
        UI.error("Not inside a git repository")
        {:error, :not_a_repo}

      {:error, reason} ->
        UI.error("Failed to list worktrees: #{format_reason(reason)}")
        {:error, reason}
    end
  end

  def run(%{conversation: conversation_id} = opts, [:create], _unknown) do
    with {:ok, project} <- Store.get_project(),
         {:ok, entry} <-
           GitCli.Worktree.create(project.name, conversation_id, Map.get(opts, :branch)) do
      UI.info("Created worktree", entry.path)
      :ok
    else
      {:error, :not_a_repo} ->
        UI.error("Not inside a git repository")
        {:error, :not_a_repo}

      {:error, reason} ->
        UI.error("Failed to create worktree: #{format_reason(reason)}")
        {:error, reason}
    end
  end

  def run(%{conversation: conv_id}, [:delete], _unknown) do
    with {:ok, meta} <- resolve_worktree_meta(conv_id),
         {:ok, root} <- GitCli.Worktree.project_root(),
         :ok <- warn_if_unmerged(root, meta),
         {:ok, :ok} <- delete_worktree(root, meta.path) do
      UI.info("Deleted worktree", meta.path)

      case GitCli.Worktree.delete_branch(root, meta.branch) do
        {:ok, :ok} -> UI.info("Deleted branch", meta.branch)
        {:error, reason} -> UI.warn("Failed to delete branch: #{format_reason(reason)}")
      end

      clear_worktree_from_conversation(conv_id)
      :ok
    else
      {:error, :cancelled} ->
        UI.info("Worktree deletion cancelled")
        :ok

      {:error, :not_a_repo} ->
        UI.error("Not inside a git repository")
        {:error, :not_a_repo}

      {:error, reason} ->
        UI.error("Failed to delete worktree: #{format_reason(reason)}")
        {:error, reason}
    end
  end

  def run(%{conversation: conv_id}, [:merge], _unknown) do
    with {:ok, meta} <- resolve_worktree_meta(conv_id),
         {:ok, root} <- GitCli.Worktree.project_root() do
      case GitCli.Worktree.Review.interactive_review(root, meta) do
        :cleaned_up -> clear_worktree_from_conversation(conv_id)
        :ok -> :ok
      end
    else
      {:error, :not_a_repo} ->
        UI.error("Not inside a git repository")
        {:error, :not_a_repo}

      {:error, reason} ->
        UI.error("Failed to merge worktree: #{format_reason(reason)}")
        {:error, reason}
    end
  end

  def run(_opts, [], _unknown) do
    UI.error("No subcommand specified. Use 'fnord worktrees --help' for help.")
  end

  def run(_opts, _subcommands, _unknown) do
    UI.error("Unknown subcommand. Use 'fnord worktrees --help' for help.")
  end

  # Warns the user if the worktree branch has not been merged into the base
  # branch. Returns :ok to continue or {:error, :cancelled} if the user
  # declines to proceed.
  @spec warn_if_unmerged(String.t(), map()) :: :ok | {:error, :cancelled}
  defp warn_if_unmerged(root, %{branch: branch, base_branch: base_branch})
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

  defp warn_if_unmerged(_root, _meta), do: :ok

  # Removes worktree metadata from the conversation and appends a system
  # message so the LLM knows the worktree is gone if the conversation is
  # continued later.
  @spec clear_worktree_from_conversation(String.t()) :: :ok
  defp clear_worktree_from_conversation(conv_id) do
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

  # Attempts a clean worktree removal. If the worktree has uncommitted changes,
  # warns the user and asks for confirmation before force-deleting.
  @spec delete_worktree(String.t(), String.t()) :: {:ok, :ok} | {:error, atom()}
  defp delete_worktree(root, path) do
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

  # Resolves worktree metadata from a conversation id by reading the
  # conversation's persisted metadata from disk.
  @spec resolve_worktree_meta(String.t()) ::
          {:ok, GitCli.Worktree.Review.worktree_info()} | {:error, atom()}
  defp resolve_worktree_meta(conv_id) do
    conv = Store.Project.Conversation.new(conv_id)

    with {:ok, data} <- Store.Project.Conversation.read(conv) do
      raw =
        data.metadata
        |> GitCli.Worktree.normalize_worktree_meta_in_parent()
        |> Map.get(:worktree)

      case raw do
        %{path: path, branch: branch} when is_binary(path) and is_binary(branch) -> {:ok, raw}
        %{path: path} when is_binary(path) -> {:ok, raw}
        _ -> {:error, :no_worktree_metadata}
      end
    end
  end

  defp format_merge_status(:merged), do: "merged"
  defp format_merge_status(:ahead), do: "ahead"
  defp format_merge_status(:diverged), do: "diverged"
  defp format_merge_status(_), do: "unknown"

  defp format_size(bytes) when bytes >= 1_048_576, do: "#{Float.round(bytes / 1_048_576, 1)} MB"
  defp format_size(bytes) when bytes >= 1_024, do: "#{Float.round(bytes / 1_024, 1)} KB"
  defp format_size(bytes), do: "#{bytes} B"

  @column_order %{"Conversation" => 0, "Branch" => 1, "Status" => 2, "Size" => 3}
  defp column_order(col), do: Map.get(@column_order, col, 99)

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
end
