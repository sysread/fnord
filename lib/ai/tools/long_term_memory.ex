defmodule AI.Tools.LongTermMemory do
  @moduledoc """
  Long-term memory tool for project and global scopes. Used internally by
  the MemoryIndexer service to persist, update, recall, and delete memories
  that have been promoted from session scope. Not exposed in the
  coordinator's toolbox -- only the background indexer pipeline calls this.
  """

  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: true

  @impl AI.Tools
  def is_available?(), do: true

  @impl AI.Tools
  @spec read_args(map) :: {:ok, map} | {:error, binary}
  def read_args(%{"action" => "recall"} = args) do
    # Validate recall args: require 'query' and 'search_type'
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
              "description" => "Content of the memory (required for remember)"
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

  @impl AI.Tools
  @spec call(map) :: {:ok, any} | {:error, any}
  def call(%{"action" => "remember"} = args) do
    with {:ok, scope} <- Map.fetch(args, "scope"),
         {:ok, title} <- Map.fetch(args, "title"),
         {:ok, content} <- Map.fetch(args, "content"),
         {:ok, scope_atom} <- parse_scope(scope) do
      topics = Map.get(args, "topics", []) |> normalize_topics()

      case Memory.new(scope_atom, title, content, topics) do
        {:ok, mem} ->
          mem_with_topics = mem |> maybe_add_topics(topics)

          case Memory.save(mem_with_topics) do
            {:ok, saved_mem} ->
              # Read back the saved memory from storage to ensure persistence
              case Memory.read(scope_atom, title) do
                {:ok, persisted} ->
                  maybe_log(:create, scope_atom, title, content)
                  {:ok, format_mem_response(persisted)}

                {:error, _} ->
                  maybe_log(:create, scope_atom, title, content)
                  {:ok, format_mem_response(saved_mem)}
              end

            {:error, reason} ->
              {:error, inspect(reason)}
          end

        {:error, :invalid_title} ->
          {:error, "invalid_title"}

        {:error, :duplicate_title} ->
          # On duplicate, replace existing memory with a conflict engram to
          # eliminate duplication and keep recall concise. We delete the old
          # memory first to avoid orphan files -- Memory.save allocates new
          # file paths via slug collision handling, so saving without deleting
          # would leave the original file on disk.
          case Memory.read(scope_atom, title) do
            {:ok, existing} ->
              prev = existing.content
              new = content

              conflict_content =
                Enum.join(
                  [
                    "Consolidated knowledge (conflict-resolved):",
                    "",
                    "Previous: " <> prev,
                    "",
                    "New: " <> new,
                    "",
                    "Resolution: consolidated to latest update."
                  ],
                  "\n"
                )

              merged =
                existing
                |> Map.put(:content, conflict_content)
                |> Map.put(:embeddings, nil)
                |> maybe_add_topics(topics)

              # Delete the old file before saving the merged version so
              # allocate_unique_path_for_title reuses the base slug path.
              Memory.forget(existing)

              case Memory.save(merged) do
                {:ok, saved_mem} ->
                  maybe_log(:consolidate, scope_atom, title, conflict_content)
                  {:ok, format_mem_response(saved_mem)}

                {:error, r} ->
                  {:error, inspect(r)}
              end

            {:error, r} ->
              {:error, inspect(r)}
          end
      end
    end
  end

  @impl AI.Tools
  def call(%{"action" => "recall"} = args) do
    do_recall(args)
  end

  @impl AI.Tools
  def call(%{"action" => "update"} = args) do
    with {:ok, scope} <- Map.fetch(args, "scope"),
         {:ok, title} <- Map.fetch(args, "title"),
         {:ok, new_content} <- Map.fetch(args, "content"),
         {:ok, scope_atom} <- parse_scope(scope),
         {:ok, mem} <- Memory.read(scope_atom, title) do
      # Replace content entirely rather than appending. The indexer agent
      # provides the complete corrected content for "replace" actions, so
      # appending would preserve stale information alongside the correction.
      updated = %{
        mem
        | content: new_content,
          embeddings: nil,
          updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      updated
      |> Memory.save()
      |> case do
        {:ok, saved} ->
          maybe_log(:update, scope_atom, title, new_content)
          {:ok, format_mem_response(saved)}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    else
      :error -> {:error, "Missing required fields 'scope', 'title', or 'content'"}
      {:error, :not_found} -> {:error, "not_found"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @impl AI.Tools
  def call(%{"action" => "forget"} = args) do
    # include Memory.read in the with so read errors flow to the else branch
    with {:ok, scope} <- Map.fetch(args, "scope"),
         {:ok, title} <- Map.fetch(args, "title"),
         {:ok, scope_atom} <- parse_scope(scope),
         {:ok, mem} <- Memory.read(scope_atom, title) do
      case Memory.forget(mem) do
        :ok ->
          maybe_log(:delete, scope_atom, title)
          {:ok, "forgotten"}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    else
      :error -> {:error, "Missing required fields 'scope' and 'title'"}
      {:error, :not_found} -> {:ok, "not_found"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def call(_), do: {:error, "unsupported"}

  defp parse_scope("project"), do: {:ok, :project}
  defp parse_scope("global"), do: {:ok, :global}

  defp parse_scope(other) do
    {:error, "Invalid scope #{inspect(other)}; expected 'project' or 'global'"}
  end

  # Safely convert status filter strings to atoms, returning nil for unknown
  # values. Uses String.to_existing_atom to avoid atom table pollution from
  # untrusted input.
  defp to_existing_status_atom(val) when is_atom(val), do: val

  defp to_existing_status_atom(val) when is_binary(val) do
    String.to_existing_atom(val)
  rescue
    ArgumentError -> nil
  end

  defp to_existing_status_atom(_), do: nil

  # Recall project and/or global memories using embeddings. When opts
  # includes :scope_filter, only the specified scope is searched. Without
  # it, both scopes are searched together.
  @spec recall_project_global(binary, non_neg_integer, map) :: {:ok, list(map)} | {:error, atom}
  defp recall_project_global(query, limit, opts) do
    status_filter = Map.get(opts, :status_filter)
    scope_filter = Map.get(opts, :scope_filter)

    provenance_only =
      case Map.get(opts, :provenance_only) do
        true -> true
        _ -> false
      end

    with {:ok, needle} <- Indexer.impl().get_embeddings(query) do
      global_candidates =
        if scope_filter in [nil, :global] do
          {:ok, titles} = Memory.Global.list()
          Enum.map(titles, fn title -> {:global, title} end)
        else
          []
        end

      project_candidates =
        if scope_filter in [nil, :project] do
          {:ok, titles} = Memory.Project.list()
          Enum.map(titles, fn title -> {:project, title} end)
        else
          []
        end

      candidates = global_candidates ++ project_candidates

      results =
        candidates
        |> Enum.map(fn {scope_atom, title} ->
          case Memory.read(scope_atom, title) do
            {:ok, mem} ->
              {mem_with_emb, score} =
                case mem.embeddings do
                  nil ->
                    case Indexer.impl().get_embeddings(mem.content) do
                      {:ok, emb} ->
                        {Map.put(mem, :embeddings, emb), AI.Util.cosine_similarity(needle, emb)}

                      _ ->
                        {mem, 0.0}
                    end

                  emb ->
                    {mem, AI.Util.cosine_similarity(needle, emb)}
                end

              status_filter_atoms =
                status_filter
                |> List.wrap()
                |> Enum.map(&to_existing_status_atom/1)
                |> Enum.reject(&is_nil/1)

              status_ok? =
                status_filter_atoms == [] or mem.index_status in status_filter_atoms

              if status_ok? do
                if provenance_only do
                  %{
                    "provenance" => %{
                      "type" => Atom.to_string(scope_atom),
                      "scope" => Atom.to_string(scope_atom),
                      "title" => title
                    },
                    "score" => score
                  }
                else
                  %{
                    "memory" => mem_to_map(mem_with_emb),
                    "score" => score,
                    "provenance" => %{
                      "type" => Atom.to_string(scope_atom),
                      "scope" => Atom.to_string(scope_atom),
                      "title" => title
                    }
                  }
                end
              else
                nil
              end

            {:error, _} ->
              nil
          end
        end)
        |> Enum.filter(& &1)
        |> Enum.sort_by(fn %{"score" => score} -> score end, :desc)
        |> Enum.take(limit)

      {:ok, results}
    else
      _ -> {:error, :embedding_failure}
    end
  end

  # Convert a Memory struct into a JSON-friendly map used in recall results.
  #
  # This helper intentionally omits embeddings to keep recall payloads
  # lightweight. Consumers who need embeddings should request them explicitly.
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

  # Recall across session memories in conversation files (provenance included)
  @spec recall_session_conversations(binary, non_neg_integer, map) ::
          {:ok, list(map)} | {:error, atom}
  defp recall_session_conversations(query, limit, opts) do
    status_filter = Map.get(opts, :status_filter)

    provenance_only =
      case Map.get(opts, :provenance_only) do
        true -> true
        _ -> false
      end

    with {:ok, needle} <- Indexer.impl().get_embeddings(query),
         {:ok, project} <- Store.get_project() do
      convs = Store.Project.Conversation.list(project)

      results =
        convs
        |> Enum.flat_map(fn convo ->
          case Store.Project.Conversation.read(convo) do
            {:ok, data} ->
              Map.get(data, :memory, [])
              |> Enum.map(fn m -> {convo.id, m} end)

            _ ->
              []
          end
        end)
        |> Enum.map(fn {conv_id, mem} ->
          {mem_with_emb, score} =
            case mem.embeddings do
              nil ->
                case Indexer.impl().get_embeddings(mem.content) do
                  {:ok, emb} ->
                    {Map.put(mem, :embeddings, emb), AI.Util.cosine_similarity(needle, emb)}

                  _ ->
                    {mem, 0.0}
                end

              emb ->
                {mem, AI.Util.cosine_similarity(needle, emb)}
            end

          status_filter_atoms =
            status_filter
            |> List.wrap()
            |> Enum.map(&to_existing_status_atom/1)
            |> Enum.reject(&is_nil/1)

          status_ok? =
            status_filter_atoms == [] or mem.index_status in status_filter_atoms

          if status_ok? do
            if provenance_only do
              %{
                "provenance" => %{
                  "type" => "session",
                  "conversation_id" => conv_id,
                  "memory_title" => mem.title
                },
                "score" => score
              }
            else
              %{
                "memory" => mem_to_map(mem_with_emb),
                "score" => score,
                "provenance" => %{
                  "type" => "session",
                  "conversation_id" => conv_id,
                  "memory_title" => mem.title
                }
              }
            end
          else
            nil
          end
        end)
        |> Enum.filter(& &1)
        |> Enum.filter(fn %{"score" => score} -> score > 0.0 end)
        |> Enum.sort_by(fn %{"score" => score} -> score end, :desc)
        |> Enum.take(limit)

      {:ok, results}
    else
      _ -> {:error, :embedding_failure}
    end
  end

  defp format_mem_response(mem) do
    "Title: #{mem.title}\nScope: #{Atom.to_string(mem.scope)}"
  end

  # Debug logging intentionally disabled by default. The wrapper remains
  # as a no-op to avoid introducing static-analysis warnings in Dialyzer.
  # Toggle behavior can be reintroduced with a simpler, well-typed helper
  # if the Dialyzer issues can be resolved safely.
  defp maybe_log(_op, _scope, _title, _detail \\ nil), do: :ok

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

  @spec do_recall(map) :: {:ok, list(map)} | {:error, binary}
  defp do_recall(%{"query" => query, "search_type" => "project_global"} = args) do
    limit = Map.get(args, "limit", 10)
    status_filter = Map.get(args, "status_filter", nil)

    provenance_only =
      case Map.get(args, "provenance_only") do
        true -> true
        _ -> false
      end

    # Optional scope filter: restrict recall to a single scope when the
    # caller wants separate global and project result sets (e.g. the
    # MemoryIndexer fetches 5 global + 5 project candidates independently).
    scope_filter =
      case Map.get(args, "scope") do
        "global" -> :global
        "project" -> :project
        _ -> nil
      end

    with {:ok, results} <-
           recall_project_global(query, limit, %{
             status_filter: status_filter,
             provenance_only: provenance_only,
             scope_filter: scope_filter
           }) do
      {:ok, results}
    else
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp do_recall(%{"query" => query, "search_type" => "session_conversations"} = args) do
    limit = Map.get(args, "limit", 10)
    status_filter = Map.get(args, "status_filter", nil)

    provenance_only =
      case Map.get(args, "provenance_only") do
        true -> true
        _ -> false
      end

    with {:ok, results} <-
           recall_session_conversations(query, limit, %{
             status_filter: status_filter,
             provenance_only: provenance_only
           }) do
      {:ok, results}
    else
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp do_recall(_) do
    {:error, "Missing required fields 'query' and/or 'search_type' for action 'recall'"}
  end
end
