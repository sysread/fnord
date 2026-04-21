defmodule AI.Tools.Git.Worktree do
  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: false

  @impl AI.Tools
  def is_available?() do
    GitCli.is_git_repo?()
  end

  @impl AI.Tools
  def read_args(args), do: {:ok, args}

  @impl AI.Tools
  def ui_note_on_request(_), do: nil

  @impl AI.Tools
  def ui_note_on_result(%{"action" => action, "branch" => branch}, _result) do
    {"Worktree", "#{branch} -> #{action}"}
  end

  def ui_note_on_result(_, _), do: nil

  @impl AI.Tools
  def tool_call_failure_message(_args, _reason), do: :default

  @impl AI.Tools
  def spec do
    %{
      type: "function",
      function: %{
        name: "git_worktree_tool",
        description: """
        Manage git worktrees for the current project conversation.

        Required fields per action:
        - list: (none, root is optional)
        - create: branch (optional, defaults to fnord-<conversation_id>)
        - commit: message (required), wip (optional, default false)
        - delete: root, path
        - merge: root, path

        Create derives the project and conversation from the active session.
        """,
        parameters: %{
          type: "object",
          additionalProperties: false,
          required: ["action"],
          properties: %{
            "action" => %{
              type: "string",
              enum: ["list", "create", "commit", "delete", "merge"],
              description: "Which worktree operation to perform."
            },
            "branch" => %{
              type: "string",
              description:
                "Optional branch name for create. Provide a short descriptive name " <>
                  "for the work being done. Defaults to fnord-<conversation_id>."
            },
            "message" => %{
              type: "string",
              description:
                "Required for commit. Commit message describing the changes. " <>
                  "When wip is true, describe what was accomplished and what problems remain."
            },
            "wip" => %{
              type: "boolean",
              description:
                "Optional for commit (default false). Set to true when stopping " <>
                  "due to blockers or incomplete work; prefixes the message with 'WIP: '."
            },
            "path" => %{
              type: "string",
              description: "Required for delete and merge. Absolute worktree path."
            },
            "root" => %{
              type: "string",
              description: "Git repo root. Required for delete and merge, optional for list."
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(%{"action" => "list"} = args) do
    root = Map.get(args, "root", GitCli.repo_root())

    with {:ok, results} <- GitCli.Worktree.list(root) do
      {:ok, results}
    end
  end

  @doc """
  Create is the integration point where a conversation-scoped worktree becomes
  part of the active session. It derives the project and conversation from the
  active session, creates the worktree, binds the resulting metadata back to
  that conversation, and rolls back the created worktree if metadata binding
  fails. An optional branch name lets the coordinator label the work.
  """
  def call(%{"action" => "create"} = args) do
    with {:ok, conversation_pid} <- active_conversation_pid(),
         {:ok, project} <- project_name(),
         conversation_id = Services.Conversation.get_id(conversation_pid),
         :ok <- check_no_existing_worktree(conversation_pid),
         {:ok, result} <-
           GitCli.Worktree.create(project, conversation_id, Map.get(args, "branch")),
         {:ok, result} <- finalize_created_worktree(conversation_pid, result) do
      Settings.set_project_root_override(result.path)
      {:ok, result}
    end
  end

  # Commits all staged and unstaged changes in the active worktree. Only works
  # in fnord-managed worktrees. When `wip` is true, prefixes the commit message
  # to signal incomplete work.
  def call(%{"action" => "commit", "message" => message} = args) do
    wip? = Map.get(args, "wip", false)

    commit_message =
      if wip? do
        # Strip any leading "WIP:" the LLM included in the message so the
        # wip prefix is applied exactly once. The tool description tells the
        # LLM to describe incomplete work, which naturally produces messages
        # that start with "WIP:", and prefixing again yields "WIP: WIP: ..."
        # on the merged commit subject.
        "WIP: #{String.replace(message, ~r/^\s*WIP:\s*/i, "")}"
      else
        # When wip? is false, respect the caller's message verbatim. Stripping
        # a leading "WIP:" here would silently rewrite an explicit intent.
        message
      end

    with {:ok, path} <- active_worktree_path(),
         {:ok, project} <- project_name(),
         true <- GitCli.Worktree.fnord_managed?(project, path) || {:error, :not_fnord_managed} do
      GitCli.Worktree.commit_all(path, commit_message)
    else
      {:error, :not_fnord_managed} ->
        {:error, "Commits via this tool are only allowed in fnord-managed worktrees."}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def call(%{"action" => "delete", "root" => root, "path" => path}) do
    GitCli.Worktree.delete(root, path)
  end

  def call(%{"action" => "merge", "root" => root, "path" => path}) do
    GitCli.Worktree.merge(root, path)
  end

  def call(%{"action" => "commit"}) do
    {:error, "Missing required field 'message' for action 'commit'"}
  end

  def call(%{"action" => action}) when action in ["delete", "merge"] do
    {:error, "Missing required fields 'root' and 'path' for worktree action"}
  end

  def call(_), do: {:error, "Missing required field 'action'"}

  # This is the handoff point between low-level worktree creation and the
  # higher-level session state that makes the worktree part of the active
  # conversation. If metadata binding fails for any reason, including a crashed
  # conversation process, the created worktree is rolled back before the error
  # is surfaced to the caller.
  @spec finalize_created_worktree(pid(), map()) :: {:ok, map()} | {:error, term()}
  defp finalize_created_worktree(conversation_pid, result) do
    try do
      case bind_worktree_to_conversation(conversation_pid, result) do
        :ok ->
          {:ok, result}

        {:error, reason} ->
          rollback_created_worktree(result)
          {:error, reason}
      end
    catch
      :exit, reason ->
        rollback_created_worktree(result)
        {:error, {:conversation_bind_failed, {:exit, reason}}}
    end
  end

  @spec rollback_created_worktree(map()) :: :ok
  defp rollback_created_worktree(%{path: path}) do
    with root when is_binary(root) <- GitCli.repo_root(),
         {:ok, :ok} <- GitCli.Worktree.delete(root, path) do
      :ok
    else
      _ -> :ok
    end
  end

  @spec active_conversation_pid() :: {:ok, pid} | {:error, String.t()}
  defp active_conversation_pid do
    case Services.Globals.get_env(:fnord, :current_conversation, nil) do
      nil ->
        {:error,
         "No active conversation is available for worktree binding. " <>
           "Create the worktree from within the target conversation session."}

      pid ->
        {:ok, pid}
    end
  end

  @spec bind_worktree_to_conversation(pid, map) :: :ok | {:error, :not_found}
  defp bind_worktree_to_conversation(pid, result) do
    meta =
      GitCli.Worktree.normalize_worktree_meta(%{
        path: result.path,
        branch: result.branch,
        base_branch: result.base_branch
      })

    Services.Conversation.upsert_conversation_meta(pid, %{worktree: meta})
  end

  @spec check_no_existing_worktree(pid) :: :ok | {:error, String.t()}
  defp check_no_existing_worktree(pid) do
    case existing_worktree_path(pid) do
      nil ->
        :ok

      path ->
        {:error,
         "This conversation already has a worktree at #{path}. " <>
           "Use the existing worktree or ask the user before creating another."}
    end
  end

  @spec existing_worktree_path(pid) :: String.t() | nil
  defp existing_worktree_path(pid) do
    pid
    |> Services.Conversation.get_conversation_meta()
    |> GitCli.Worktree.normalize_worktree_meta_in_parent()
    |> case do
      %{worktree: %{path: path}} when is_binary(path) -> path
      _ -> nil
    end
  end

  @spec active_worktree_path() :: {:ok, String.t()} | {:error, String.t()}
  defp active_worktree_path do
    case Settings.get_project_root_override() do
      nil -> {:error, "No active worktree for this conversation."}
      path -> {:ok, path}
    end
  end

  @spec project_name() :: {:ok, String.t()} | {:error, String.t()}
  defp project_name do
    case Store.get_project() do
      {:ok, project} -> {:ok, project.name}
      _ -> {:error, "No project selected."}
    end
  end
end
