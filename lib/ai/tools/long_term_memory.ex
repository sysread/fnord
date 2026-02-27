defmodule AI.Tools.LongTermMemory do
  @moduledoc """
  Long-term memory tool for project and global scopes. Used internally by
  the MemoryIndexer service to persist, update, recall, and delete memories
  that have been promoted from session scope. Not exposed in the
  coordinator's toolbox -- only the background indexer pipeline calls this.
  """

  @behaviour AI.Tools

  # --------------------------------------------------------------------------
  # AI.Tools behaviour
  # --------------------------------------------------------------------------
  @impl AI.Tools
  def async?, do: true

  @impl AI.Tools
  def is_available?(), do: true

  @impl AI.Tools
  @spec read_args(map) :: {:ok, map} | {:error, binary}
  def read_args(%{"action" => "recall"} = args) do
    case {Map.get(args, "query"), Map.get(args, "search_type")} do
      {q, s}
      when is_binary(q) and is_binary(s) and s in ["project_global", "session_conversations"] ->
        {:ok, args}

      _ ->
        {:error,
         "Invalid recall args: require 'query' (string) and 'search_type' ('project_global'|'session_conversations')"}
    end
  end

  def read_args(args), do: {:ok, args}

  @impl AI.Tools
  def ui_note_on_request(_), do: nil

  @impl AI.Tools
  def ui_note_on_result(_req, _res), do: nil

  @impl AI.Tools
  def tool_call_failure_message(_args, _reason), do: :default

  @impl AI.Tools
  def spec do
    %{
      type: "function",
      function: %{
        name: "long_term_memory_tool",
        description: "Long-term memory tool (project/global).",
        parameters: %{
          type: "object",
          additionalProperties: false,
          required: ["action"],
          properties: %{
            "action" => %{
              "type" => "string",
              "description" => "Action to perform: 'remember' | 'recall' | 'update' | 'forget'"
            },
            "scope" => %{
              "type" => "string",
              "description" => "Memory scope: 'project' | 'global'"
            },
            "title" => %{
              "type" => "string",
              "description" => "Title of the memory (required for remember/update/forget)"
            },
            "content" => %{
              "type" => "string",
              "description" => "Content of the memory (required for remember and update)"
            },
            "query" => %{
              "type" => "string",
              "description" => "Search query string for recall"
            },
            "search_type" => %{
              "type" => "string",
              "description" => "Recall search type: 'project_global' | 'session_conversations'"
            },
            "limit" => %{
              "type" => "integer",
              "description" => "Maximum number of recall results to return"
            },
            "status_filter" => %{
              "anyOf" => [
                %{"type" => "string"},
                %{"type" => "array", "items" => %{"type" => "string"}}
              ],
              "description" => "Filter recall results by index status (string or list of strings)"
            },
            "provenance_only" => %{
              "type" => "boolean",
              "description" => "If true, return only provenance information for recall results"
            }
          }
        }
      }
    }
  end

  # --------------------------------------------------------------------------
  # Actions
  # --------------------------------------------------------------------------

  # Remember: create a new memory, or conflict-resolve if duplicate title.
  @impl AI.Tools
  @spec call(map) :: {:ok, any} | {:error, any}
  def call(%{"action" => "remember"} = args) do
    with {:ok, scope_atom} <- fetch_scope(args),
         {:ok, title} <- Map.fetch(args, "title"),
         {:ok, content} <- Map.fetch(args, "content") do
      topics = args |> Map.get("topics", []) |> normalize_topics()
      create_or_resolve_conflict(scope_atom, title, content, topics)
    end
  end

  # Recall: search across scopes using embeddings.
  @impl AI.Tools
  def call(%{"action" => "recall"} = args), do: do_recall(args)

  # Update: replace the content of an existing memory entirely.
  @impl AI.Tools
  def call(%{"action" => "update"} = args) do
    with {:ok, scope_atom} <- fetch_scope(args),
         {:ok, title} <- Map.fetch(args, "title"),
         {:ok, content} <- Map.fetch(args, "content"),
         {:ok, mem} <- Memory.read(scope_atom, title),
         {:ok, saved} <- replace_content(mem, content) do
      {:ok, format_mem_response(saved)}
    else
      :error -> {:error, "Missing required fields 'scope', 'title', or 'content'"}
      {:error, :not_found} -> {:error, "not_found"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # Forget: delete an existing memory.
  @impl AI.Tools
  def call(%{"action" => "forget"} = args) do
    with {:ok, scope_atom} <- fetch_scope(args),
         {:ok, title} <- Map.fetch(args, "title"),
         {:ok, mem} <- Memory.read(scope_atom, title),
         :ok <- Memory.forget(mem) do
      {:ok, "forgotten"}
    else
      :error -> {:error, "Missing required fields 'scope' and 'title'"}
      {:error, :not_found} -> {:ok, "not_found"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def call(_), do: {:error, "unsupported"}

  # --------------------------------------------------------------------------
  # Remember helpers
  # --------------------------------------------------------------------------

  # Try to create a new memory. On duplicate title, read the existing memory
  # and merge the two into a single conflict-resolved entry.
  @spec create_or_resolve_conflict(Memory.scope(), binary, binary, list(binary)) ::
          {:ok, binary} | {:error, binary}
  defp create_or_resolve_conflict(scope, title, content, topics) do
    case Memory.new(scope, title, content, topics) do
      {:ok, mem} ->
        mem
        |> maybe_add_topics(topics)
        |> save_and_verify(scope, title)

      {:error, :invalid_title} ->
        {:error, "invalid_title"}

      {:error, :duplicate_title} ->
        resolve_conflict(scope, title, content, topics)
    end
  end

  # Save a memory and read it back to confirm persistence.
  defp save_and_verify(mem, scope, title) do
    with {:ok, saved} <- Memory.save(mem) do
      case Memory.read(scope, title) do
        {:ok, persisted} -> {:ok, format_mem_response(persisted)}
        {:error, _} -> {:ok, format_mem_response(saved)}
      end
    else
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # On duplicate title, synthesize a conflict-resolved memory that combines
  # the old and new content, then delete-and-recreate to avoid orphan files.
  defp resolve_conflict(scope, title, new_content, topics) do
    with {:ok, existing} <- Memory.read(scope, title) do
      merged = build_conflict_engram(existing, new_content, topics)
      Memory.forget(existing)

      case Memory.save(merged) do
        {:ok, saved} -> {:ok, format_mem_response(saved)}
        {:error, r} -> {:error, inspect(r)}
      end
    else
      {:error, r} -> {:error, inspect(r)}
    end
  end

  defp build_conflict_engram(existing, new_content, topics) do
    conflict_content =
      Enum.join(
        [
          "Consolidated knowledge (conflict-resolved):",
          "",
          "Previous: " <> existing.content,
          "",
          "New: " <> new_content,
          "",
          "Resolution: consolidated to latest update."
        ],
        "\n"
      )

    existing
    |> Map.put(:content, conflict_content)
    |> Map.put(:embeddings, nil)
    |> maybe_add_topics(topics)
  end

  # --------------------------------------------------------------------------
  # Update helpers
  # --------------------------------------------------------------------------

  # Replace the content of an existing memory entirely. The indexer agent
  # provides complete corrected content for "replace" actions, so appending
  # would preserve stale information alongside the correction.
  defp replace_content(mem, content) do
    %{
      mem
      | content: content,
        embeddings: nil,
        updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
    |> Memory.save()
  end

  # --------------------------------------------------------------------------
  # Recall dispatch
  # --------------------------------------------------------------------------
  @spec do_recall(map) :: {:ok, list(map)} | {:error, binary}
  defp do_recall(%{"query" => query, "search_type" => "project_global"} = args) do
    opts = extract_recall_opts(args)

    case recall_project_global(query, opts.limit, opts) do
      {:ok, results} -> {:ok, results}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp do_recall(%{"query" => query, "search_type" => "session_conversations"} = args) do
    opts = extract_recall_opts(args)

    case recall_session_conversations(query, opts.limit, opts) do
      {:ok, results} -> {:ok, results}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp do_recall(_) do
    {:error, "Missing required fields 'query' and/or 'search_type' for action 'recall'"}
  end

  defp extract_recall_opts(args) do
    %{
      limit: Map.get(args, "limit", 10),
      status_filter: Map.get(args, "status_filter"),
      provenance_only: Map.get(args, "provenance_only") == true,
      scope_filter: parse_scope_filter(Map.get(args, "scope"))
    }
  end

  # --------------------------------------------------------------------------
  # Recall: project/global scope
  # --------------------------------------------------------------------------

  # Searches project and/or global memories using embedding similarity. When
  # opts includes :scope_filter, only the specified scope is searched.
  @spec recall_project_global(binary, non_neg_integer, map) :: {:ok, list(map)} | {:error, atom}
  defp recall_project_global(query, limit, opts) do
    with {:ok, needle} <- Indexer.impl().get_embeddings(query) do
      opts
      |> list_candidates_for_scope()
      |> score_and_filter_candidates(needle, opts)
      |> Enum.take(limit)
      |> then(&{:ok, &1})
    else
      _ -> {:error, :embedding_failure}
    end
  end

  # --------------------------------------------------------------------------
  # Recall: session conversations
  # --------------------------------------------------------------------------

  # Searches session memories embedded in conversation files.
  @spec recall_session_conversations(binary, non_neg_integer, map) ::
          {:ok, list(map)} | {:error, atom}
  defp recall_session_conversations(query, limit, opts) do
    with {:ok, needle} <- Indexer.impl().get_embeddings(query),
         {:ok, project} <- Store.get_project() do
      project
      |> collect_session_memories()
      |> score_session_memories(needle, opts)
      |> Enum.filter(fn %{"score" => score} -> score > 0.0 end)
      |> Enum.take(limit)
      |> then(&{:ok, &1})
    else
      _ -> {:error, :embedding_failure}
    end
  end

  # --------------------------------------------------------------------------
  # Recall building blocks
  # --------------------------------------------------------------------------

  # List candidate {scope, title} tuples based on scope_filter.
  defp list_candidates_for_scope(%{scope_filter: scope_filter}) do
    global =
      if scope_filter in [nil, :global] do
        {:ok, titles} = Memory.Global.list()
        Enum.map(titles, fn t -> {:global, t} end)
      else
        []
      end

    project =
      if scope_filter in [nil, :project] do
        {:ok, titles} = Memory.Project.list()
        Enum.map(titles, fn t -> {:project, t} end)
      else
        []
      end

    global ++ project
  end

  # Score each candidate against the query needle, apply status filters,
  # format results, and sort by descending score.
  defp score_and_filter_candidates(candidates, needle, opts) do
    status_atoms = parse_status_filter(opts[:status_filter])

    candidates
    |> Enum.map(fn {scope_atom, title} -> score_memory(scope_atom, title, needle) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(fn {_mem, _score} -> true end)
    |> Enum.filter(fn {mem, _score} -> passes_status_filter?(mem, status_atoms) end)
    |> Enum.sort_by(fn {_mem, score} -> score end, :desc)
    |> Enum.map(fn {mem, score} -> format_recall_result(mem, score, opts[:provenance_only]) end)
  end

  # Read a memory, compute its similarity score against the needle,
  # generating embeddings on-demand if missing.
  defp score_memory(scope_atom, title, needle) do
    case Memory.read(scope_atom, title) do
      {:ok, mem} ->
        {mem_with_emb, score} = ensure_embeddings_and_score(mem, needle)
        {mem_with_emb, score}

      {:error, _} ->
        nil
    end
  end

  defp ensure_embeddings_and_score(%{embeddings: nil} = mem, needle) do
    case Indexer.impl().get_embeddings(mem.content) do
      {:ok, emb} ->
        {%{mem | embeddings: emb}, AI.Util.cosine_similarity(needle, emb)}

      _ ->
        {mem, 0.0}
    end
  end

  defp ensure_embeddings_and_score(%{embeddings: emb} = mem, needle) do
    {mem, AI.Util.cosine_similarity(needle, emb)}
  end

  # Collect all session memories from conversation files, paired with their
  # conversation ID for provenance tracking.
  defp collect_session_memories(project) do
    project
    |> Store.Project.Conversation.list()
    |> Enum.flat_map(fn convo ->
      case Store.Project.Conversation.read(convo) do
        {:ok, data} ->
          data
          |> Map.get(:memory, [])
          |> Enum.map(fn m -> {convo.id, m} end)

        _ ->
          []
      end
    end)
  end

  # Score session memories and format results with conversation provenance.
  defp score_session_memories(memories, needle, opts) do
    status_atoms = parse_status_filter(opts[:status_filter])

    memories
    |> Enum.map(fn {conv_id, mem} ->
      {mem_with_emb, score} = ensure_embeddings_and_score(mem, needle)
      {conv_id, mem_with_emb, score}
    end)
    |> Enum.filter(fn {_id, mem, _score} -> passes_status_filter?(mem, status_atoms) end)
    |> Enum.sort_by(fn {_id, _mem, score} -> score end, :desc)
    |> Enum.map(fn {conv_id, mem, score} ->
      format_session_recall_result(conv_id, mem, score, opts[:provenance_only])
    end)
  end

  # --------------------------------------------------------------------------
  # Status filter
  # --------------------------------------------------------------------------
  defp parse_status_filter(nil), do: []

  defp parse_status_filter(filter) do
    filter
    |> List.wrap()
    |> Enum.map(&to_existing_status_atom/1)
    |> Enum.reject(&is_nil/1)
  end

  defp passes_status_filter?(_mem, []), do: true
  defp passes_status_filter?(mem, atoms), do: mem.index_status in atoms

  # Safely convert status filter strings to atoms, returning nil for unknown
  # values. Uses String.to_existing_atom to avoid atom table pollution.
  defp to_existing_status_atom(val) when is_atom(val), do: val

  defp to_existing_status_atom(val) when is_binary(val) do
    String.to_existing_atom(val)
  rescue
    ArgumentError -> nil
  end

  defp to_existing_status_atom(_), do: nil

  # --------------------------------------------------------------------------
  # Result formatting
  # --------------------------------------------------------------------------

  defp format_recall_result(mem, score, true = _provenance_only) do
    %{
      "provenance" => %{
        "type" => Atom.to_string(mem.scope),
        "scope" => Atom.to_string(mem.scope),
        "title" => mem.title
      },
      "score" => score
    }
  end

  defp format_recall_result(mem, score, _provenance_only) do
    %{
      "memory" => mem_to_map(mem),
      "score" => score,
      "provenance" => %{
        "type" => Atom.to_string(mem.scope),
        "scope" => Atom.to_string(mem.scope),
        "title" => mem.title
      }
    }
  end

  defp format_session_recall_result(conv_id, mem, score, true = _provenance_only) do
    %{
      "provenance" => %{
        "type" => "session",
        "conversation_id" => conv_id,
        "memory_title" => mem.title
      },
      "score" => score
    }
  end

  defp format_session_recall_result(conv_id, mem, score, _provenance_only) do
    %{
      "memory" => mem_to_map(mem),
      "score" => score,
      "provenance" => %{
        "type" => "session",
        "conversation_id" => conv_id,
        "memory_title" => mem.title
      }
    }
  end

  # Converts a Memory struct to a JSON-friendly map, omitting embeddings
  # to keep recall payloads lightweight.
  @spec mem_to_map(Memory.t()) :: map
  defp mem_to_map(%Memory{} = mem) do
    %{
      title: mem.title,
      content: mem.content,
      topics: mem.topics || [],
      scope: Atom.to_string(mem.scope),
      index_status: mem.index_status,
      inserted_at: mem.inserted_at,
      updated_at: mem.updated_at
    }
  end

  defp format_mem_response(mem) do
    "Title: #{mem.title}\nScope: #{Atom.to_string(mem.scope)}"
  end

  # --------------------------------------------------------------------------
  # Shared helpers
  # --------------------------------------------------------------------------
  defp fetch_scope(args) do
    with {:ok, scope} <- Map.fetch(args, "scope") do
      parse_scope(scope)
    end
  end

  defp parse_scope("project"), do: {:ok, :project}
  defp parse_scope("global"), do: {:ok, :global}

  defp parse_scope(other) do
    {:error, "Invalid scope #{inspect(other)}; expected 'project' or 'global'"}
  end

  defp parse_scope_filter("global"), do: :global
  defp parse_scope_filter("project"), do: :project
  defp parse_scope_filter(_), do: nil

  defp normalize_topics(nil), do: []

  defp normalize_topics(topics) when is_list(topics) do
    topics
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_topics(topic) when is_binary(topic) do
    topic
    |> String.split(~r/[,|]/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp maybe_add_topics(memory, topics) do
    new_topics = normalize_topics(topics)

    if new_topics == [] do
      memory
    else
      existing =
        case Map.get(memory, :topics) do
          list when is_list(list) -> list
          _ -> []
        end

      %{memory | topics: Enum.uniq(existing ++ new_topics)}
    end
  end
end
