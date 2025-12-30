defmodule AI.Tools.Memory do
  alias Memory.Presentation
  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: true

  @impl AI.Tools
  def is_available?(), do: Memory.is_available?()

  @impl AI.Tools
  def ui_note_on_request(%{"action" => "list"}) do
    {"Listing memories", "Listing all memories grouped by scope (session, project, global)."}
  end

  def ui_note_on_request(%{"action" => "recall", "scope" => scope, "what" => what}) do
    {"Recalling memories", "<#{scope}> " <> what}
  end

  def ui_note_on_request(%{"action" => "remember", "scope" => scope, "title" => title}) do
    {"Note to self", "<#{scope}> " <> title}
  end

  def ui_note_on_request(%{"action" => "update", "scope" => scope, "title" => title}) do
    {"Note to self", "<#{scope}> " <> title}
  end

  def ui_note_on_request(%{"action" => "forget", "scope" => scope, "title" => title}) do
    {"Forgetting", "<#{scope}> " <> title}
  end

  def ui_note_on_request(_), do: nil

  @impl AI.Tools
  def ui_note_on_result(_request, _result), do: nil

  @impl AI.Tools
  def tool_call_failure_message(_args, _reason), do: :default

  @impl AI.Tools
  def read_args(args), do: {:ok, args}

  @impl AI.Tools
  def spec do
    %{
      type: "function",
      function: %{
        name: "memory_tool",
        description: """
        Interact with long-term memories across session, project, and global scopes.

        Primary use: WRITE memories (action=remember/update) when you learn stable information that will help future sessions.

        When to WRITE (strong triggers):
        - The user states a stable preference (format, tone, workflow, tools).
        - The user states a stable project convention (terminology, architecture, testing norms, gotchas).
        - The user corrects or retracts a previously stated preference/convention.
        - You identify an improvement to your stable working habits or persona. When this happens, update the global memory titled "Me".

        Defaults:
        - Prefer scope=global for user preferences.
        - Prefer scope=project for project-specific conventions.
        - Prefer action=update when refining an existing memory.

        Hard rule:
        Do NOT store or rely on the assistant's current conversation name/ID in long-term memory; that name is assigned per conversation and may change. Focus on stable traits, preferences, and project facts instead.
        """,
        parameters: %{
          type: "object",
          additionalProperties: false,
          required: ["action"],
          properties: %{
            "action" => %{
              type: "string",
              enum: ["list", "recall", "remember", "update", "forget"],
              description: """
              Which memory operation to perform.

              - list: List all memories
                - args: none

              - recall: Search for similar memories
                - args:
                  - required: what
                  - optional: limit

              - remember: Create a new memory
                - args:
                  - required: scope, title, content
                  - optional: topics

              - update: Append content to an existing memory
                - args:
                  - required: scope, title, new_content
                  - optional: new_topics

              - forget: Delete a memory
                - args:
                  - required: title
                  - optional: scope
              """
            },
            "scope" => %{
              type: "string",
              enum: ["session", "project", "global"],
              description: """
              Memory scope for remember/update/forget operations.
              - session: Memory lasts for the current session only. This is appropriate for ephemeral notes about the current conversation, such as current goals, tasks, or decision-making while brainstorming.
              - project: Memory is stored within the current project and shared across sessions. This is appropriate for project-specific information that should persist, such as project organization, terminology, gotchas and closet skeletons related to the project.
              - global: Memory is stored globally and shared across all projects and sessions. This is appropriate for general knowledge, preferences, observations about the user, and other information that should be globally available to you.
              """
            },
            "what" => %{
              type: "string",
              description: "Text to search for similar memories (action=recall)."
            },
            "limit" => %{
              type: "integer",
              description: "Maximum number of memories to return (action=recall).",
              default: 5
            },
            "title" => %{
              type: "string",
              description:
                "Title of the memory (remember/update/forget). Must be unique within the specified scope and alphanumeric (single spaces are fine)."
            },
            "content" => %{
              type: "string",
              description: "Content of the memory (remember)."
            },
            "topics" => %{
              type: "array",
              items: %{type: "string"},
              description: "Optional list of topics related to the memory (remember)."
            },
            "new_content" => %{
              type: "string",
              description: "Content to append to an existing memory (update)."
            },
            "new_topics" => %{
              type: "array",
              items: %{type: "string"},
              description: "Optional list of new topics to add to the memory (update)."
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(%{"action" => "list"} = _args), do: do_list()
  def call(%{"action" => "recall"} = args), do: do_recall(args)
  def call(%{"action" => "remember"} = args), do: do_remember(args)
  def call(%{"action" => "update"} = args), do: do_update(args)
  def call(%{"action" => "forget"} = args), do: do_forget(args)
  def call(_), do: {:error, "Invalid or missing 'action' for memory_tool"}

  # ---------------------------------------------------------------------------
  # Operations
  # ---------------------------------------------------------------------------
  @default_search_limit 5

  defp do_list() do
    case Memory.list() do
      {:ok, memories} -> {:ok, Enum.map(memories, &format_memory/1)}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp do_recall(%{"what" => query} = args) do
    limit = Map.get(args, "limit", @default_search_limit)

    query
    |> String.trim()
    |> Memory.search(limit)
    |> case do
      {:ok, results} ->
        payload =
          results
          |> Enum.map(fn {mem, score} ->
            # Drop embeddings from the result for cleaner JSON output
            %{
              title: mem.title,
              scope: Atom.to_string(mem.scope),
              topics: Enum.join(mem.topics, " | "),
              score: score,
              content: mem.content
            }
          end)

        {:ok, payload}

      {:error, :not_implemented} ->
        # Treat not-implemented search as an empty result for now.
        {:ok, []}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp do_recall(_) do
    {:error, "Missing required field 'what' for action 'recall'"}
  end

  defp do_remember(%{"scope" => scope, "title" => title, "content" => content} = args) do
    with {:ok, scope_atom} <- parse_scope(scope),
         topics <- Map.get(args, "topics", []),
         {:ok, memory} <- new_memory(scope_atom, title, content, topics),
         {:ok, saved} <- wrap_save(Memory.save(memory), memory) do
      {:ok, format_memory(saved)}
    end
  end

  defp do_remember(_) do
    {:error, "Missing required fields 'scope', 'title', and 'content' for action 'remember'"}
  end

  defp do_update(%{"scope" => scope, "title" => title, "new_content" => new_content} = args) do
    case parse_scope(scope) do
      {:ok, scope_atom} ->
        case Memory.read(scope_atom, title) do
          {:ok, memory} ->
            new_topics = Map.get(args, "new_topics", [])

            updated =
              memory
              |> Memory.append(new_content)
              |> maybe_add_topics(new_topics)

            case wrap_save(Memory.save(updated), updated) do
              {:ok, saved} ->
                {:ok, format_memory(saved)}

              {:error, _} = error ->
                error
            end

          {:error, :not_found} ->
            {:error,
             "No memory found with title #{inspect(title)} in #{Atom.to_string(scope_atom)} scope. Use action=list to see available memories."}

          {:error, reason} ->
            {:error, inspect(reason)}
        end

      {:error, _} = error ->
        error
    end
  end

  defp do_update(_) do
    {:error, "Missing required fields 'scope', 'title', and 'new_content' for action 'update'"}
  end

  defp do_forget(%{"title" => title} = args) do
    scope_opt = Map.get(args, "scope")

    scopes =
      case scope_opt do
        nil ->
          [:session, :project, :global]

        s ->
          with {:ok, atom} <- parse_scope(s) do
            [atom]
          end
      end

    case find_memory_by_title(scopes, title) do
      {:ok, memory} -> Memory.forget(memory)
      :not_found -> :ok
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp do_forget(_) do
    {:error, "Missing required field 'title' for action 'forget'"}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp parse_scope("session"), do: {:ok, :session}
  defp parse_scope("project"), do: {:ok, :project}
  defp parse_scope("global"), do: {:ok, :global}

  defp parse_scope(other) do
    {:error, "Invalid scope #{inspect(other)}; expected 'session', 'project', or 'global'"}
  end

  defp maybe_add_topics(memory, []), do: memory

  defp maybe_add_topics(memory, topics) when is_list(topics) do
    existing = Map.get(memory, :topics, [])
    %{memory | topics: Enum.uniq(existing ++ topics)}
  end

  defp maybe_add_topics(memory, _), do: memory

  defp wrap_save({:ok, saved}, _memory), do: {:ok, saved}
  defp wrap_save({:error, _} = error, _memory), do: error

  defp new_memory(scope_atom, title, content, topics) do
    case Memory.new(scope_atom, title, content, topics) do
      {:ok, memory} ->
        {:ok, memory}

      {:error, :invalid_title} ->
        reasons =
          case Memory.validate_title(title) do
            {:error, reasons} -> reasons
            :ok -> ["title failed validation (no further details available)"]
          end

        bullet_reasons = Enum.map_join(reasons, "\n", fn reason -> "- " <> reason end)

        {:error,
         """
         Invalid memory title #{inspect(title)}.
         Reasons:
         #{bullet_reasons}

         Examples of valid titles:
         - "Meeting Notes"
         - "Project Architecture"
         - "User Preferences"
         """}

      {:error, :duplicate_title} ->
        {:error,
         "Memory title #{inspect(title)} already exists in #{Atom.to_string(scope_atom)} scope. Use action=update to modify the existing memory."}
    end
  end

  defp find_memory_by_title(scopes, title) do
    scopes
    |> Enum.reduce_while(:not_found, fn scope, _acc ->
      case Memory.read(scope, title) do
        {:ok, memory} -> {:halt, {:ok, memory}}
        {:error, _} -> {:cont, :not_found}
      end
    end)
  end

  defp format_memory(%Memory{} = memory) do
    now = DateTime.utc_now()
    age = Presentation.age_line(memory, now)
    warning = Presentation.warning_line(memory, now)

    warning_line =
      if warning do
        "#{warning}\n"
      else
        ""
      end

    """
    Title: #{memory.title}
    Scope: #{Atom.to_string(memory.scope)}
    Topics: #{Enum.join(memory.topics, " | ")}
    #{age}
    #{warning_line}Content:
    #{memory.content}
    """
  end

  defp format_memory({%Memory{} = memory, score}) do
    now = DateTime.utc_now()
    age = Presentation.age_line(memory, now)
    warning = Presentation.warning_line(memory, now)

    warning_line =
      if warning do
        "#{warning}\n"
      else
        ""
      end

    """
    Title: #{memory.title}
    Score: #{Float.round(score, 4)}
    Scope: #{Atom.to_string(memory.scope)}
    Topics: #{Enum.join(memory.topics, " | ")}
    #{age}
    #{warning_line}Content:
    #{memory.content}
    """
  end

  defp format_memory({scope, title}) when is_atom(scope) and is_binary(title) do
    """
    Title: #{title}
    Scope: #{Atom.to_string(scope)}
    """
  end

  defp format_memory(other) do
    inspect(other)
  end
end
