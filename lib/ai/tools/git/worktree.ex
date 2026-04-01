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

  def call(
        %{"action" => "create", "project" => project, "conversation_id" => conversation_id} = args
      ) do
    # Guard: a conversation may have at most one worktree association
    with :ok <- check_no_existing_worktree(),
         {:ok, result} <- GitCli.Worktree.create(project, conversation_id, Map.get(args, "branch")),
         :ok <- bind_worktree_to_conversation(result) do
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

  # Persists the worktree association to conversation metadata so that
  # resume, recreate, and coordinator bootstrap all see a consistent state.
  defp bind_worktree_to_conversation(result) do
    case Services.Globals.get_env(:fnord, :current_conversation, nil) do
      nil ->
        :ok

      pid ->
        meta = %{path: result.path, branch: result.branch, base_branch: result.base_branch}
        Services.Conversation.upsert_conversation_meta(pid, %{worktree: meta})
    end
  end

  # Returns :ok if no worktree is already bound to the current conversation,
  # or an error guiding the model to reuse the existing one.
  defp check_no_existing_worktree do
    case Services.Globals.get_env(:fnord, :current_conversation, nil) do
      nil ->
        :ok

      pid ->
        meta = Services.Conversation.get_conversation_meta(pid)

        case meta do
          %{worktree: %{path: path}} when is_binary(path) ->
            {:error,
             "This conversation already has a worktree at #{path}. " <>
               "Use the existing worktree or ask the user before creating another."}

          _ ->
            :ok
        end
    end
  end
end
