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
    with {:ok, root} <- GitCli.Worktree.project_root(),
         {:ok, entries} <- GitCli.Worktree.list(root) do
      Enum.each(entries, fn entry ->
        UI.puts("#{entry.path}\t#{entry.branch}\t#{entry.merge_status}\t#{entry.size}")
      end)

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
         {:ok, :ok} <- GitCli.Worktree.delete(root, meta.path) do
      UI.info("Deleted worktree", meta.path)

      case GitCli.Worktree.delete_branch(root, meta.branch) do
        {:ok, :ok} -> UI.info("Deleted branch", meta.branch)
        {:error, reason} -> UI.warn("Failed to delete branch: #{format_reason(reason)}")
      end

      :ok
    else
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
      GitCli.Worktree.Review.interactive_review(root, meta)
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

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
end
