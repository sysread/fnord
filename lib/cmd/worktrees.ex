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
            about: "Remove a worktree by path",
            options: [
              path: [
                value_name: "PATH",
                long: "--path",
                short: "-P",
                help: "Absolute worktree path to remove",
                parser: :string,
                required: true
              ]
            ]
          ],
          merge: [
            name: "merge",
            about: "Merge a worktree branch and remove the worktree",
            options: [
              path: [
                value_name: "PATH",
                long: "--path",
                short: "-P",
                help: "Absolute worktree path to merge",
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

  def run(%{path: path}, [:delete], _unknown) do
    with {:ok, root} <- GitCli.Worktree.project_root(),
         {:ok, :ok} <- GitCli.Worktree.delete(root, path) do
      UI.info("Deleted worktree", path)
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

  def run(%{path: path}, [:merge], _unknown) do
    with {:ok, root} <- GitCli.Worktree.project_root(),
         {:ok, :ok} <- GitCli.Worktree.merge(root, path) do
      UI.info("Merged worktree", path)
      :ok
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

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
end
