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
  def ui_note_on_request(%{"action" => action}) do
    {"Managing git worktree", action}
  end

  def ui_note_on_request(_), do: nil

  @impl AI.Tools
  def ui_note_on_result(%{"action" => action}, _result) do
    {"Managed git worktree", action}
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
        - create: project, conversation_id (branch is optional)
        - delete: root, path
        - merge: root, path
        """,
        parameters: %{
          type: "object",
          additionalProperties: false,
          required: ["action"],
          properties: %{
            "action" => %{
              type: "string",
              enum: ["list", "create", "delete", "merge"],
              description: "Which worktree operation to perform."
            },
            "project" => %{
              type: "string",
              description: "Required for create. Project name for worktree path resolution."
            },
            "conversation_id" => %{
              type: "string",
              description: "Required for create. Conversation id for worktree naming."
            },
            "branch" => %{
              type: "string",
              description: "Optional branch name for create. Defaults to a generated branch."
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
  part of the active session. It verifies the live conversation identity,
  creates the worktree, binds the resulting metadata back to that same
  conversation, and rolls back the created worktree if metadata binding fails.
  """
  def call(
        %{"action" => "create", "project" => project, "conversation_id" => conversation_id} = args
      ) do
    with {:ok, conversation_pid} <- conversation_pid_for(conversation_id),
         :ok <- check_no_existing_worktree(conversation_pid),
         {:ok, result} <-
           GitCli.Worktree.create(project, conversation_id, Map.get(args, "branch")),
         {:ok, result} <- finalize_created_worktree(conversation_pid, result) do
      Settings.set_project_root_override(result.path)
      {:ok, result}
    end
  end

  def call(%{"action" => "delete", "root" => root, "path" => path}) do
    GitCli.Worktree.delete(root, path)
  end

  def call(%{"action" => "merge", "root" => root, "path" => path}) do
    GitCli.Worktree.merge(root, path)
  end

  def call(%{"action" => "create"}) do
    {:error, "Missing required fields 'project' and 'conversation_id' for action 'create'"}
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

  @spec conversation_pid_for(String.t()) :: {:ok, pid} | {:error, String.t()}
  defp conversation_pid_for(conversation_id) do
    case Services.Globals.get_env(:fnord, :current_conversation, nil) do
      nil ->
        {:error,
         "No active conversation is available for worktree binding. " <>
           "Create the worktree from within the target conversation session."}

      pid ->
        case Services.Conversation.get_id(pid) do
          ^conversation_id -> {:ok, pid}
          other -> {:error, conversation_mismatch_error(conversation_id, other)}
        end
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

  @spec conversation_mismatch_error(String.t(), String.t()) :: String.t()
  defp conversation_mismatch_error(requested, actual) do
    "Cannot bind a worktree for conversation #{requested} while the active " <>
      "conversation is #{actual}. Create the worktree from the matching " <>
      "conversation session instead."
  end
end
