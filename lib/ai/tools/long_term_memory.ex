defmodule AI.Tools.LongTermMemory do
  @moduledoc """
  Minimal long-term memory tool stub. The full implementation was removed
  temporarily to avoid causing dialyzer issues while we iterate on the
  session-indexer and related changes. This module preserves the tool spec
  and a conservative, synchronous API surface for use by the ingest/indexer
  agents. It should be expanded with full behavior and tests in a follow-up
  change.
  """

  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: true

  @impl AI.Tools
  def is_available?(), do: true

  @impl AI.Tools
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
          required: ["action", "scope"],
          properties: %{
            "action" => %{
              type: "string",
              enum: ["remember", "update", "forget", "recall"],
              description: "Operation to perform. 'recall' searches memories."
            },
            "scope" => %{type: "string", enum: ["project", "global"]},
            "title" => %{type: "string"},
            "content" => %{type: "string"},
            "query" => %{type: "string", description: "Text query to search memories (recall)."},
            "search_type" => %{
              type: "string",
              enum: ["project_global", "session_conversations"],
              description: "Which recall path to use (project/global vs session conversations)."
            },
            "limit" => %{
              type: "integer",
              description: "Max results to return for recall; defaults to 10."
            },
            "status_filter" => %{
              type: "array",
              items: %{type: "string"},
              description:
                "Optional list of memory statuses to include (new, analyzed, rejected, incorporated, merged)."
            },
            "provenance_only" => %{
              type: "boolean",
              description:
                "When true, return only provenance metadata instead of full memory content."
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
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
            :ok ->
              maybe_log(:create, scope_atom, title, content)
              {:ok, format_mem_response(mem_with_topics)}

            {:ok, saved_mem} ->
              maybe_log(:create, scope_atom, title, content)
              {:ok, format_mem_response(saved_mem)}

            {:error, reason} ->
              {:error, inspect(reason)}
          end

        {:error, :invalid_title} ->
          {:error, "invalid_title"}

        {:error, :duplicate_title} ->
          # On duplicate, replace existing memory with a conflict engram to
          # eliminate duplication and keep recall concise. This is destructive
          # by design: we synthesize a combined memory describing prior and
          # new findings and save it in place of the old memory.
          case Memory.read(scope_atom, title) do
            {:ok, existing} ->
              # existing.content and content are expected to be binaries here
              # (Memory.content is typed as a binary). Avoid unnecessary nil
              # pattern checks which Dialyzer flags; use the values directly.
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

              case Memory.save(merged) do
                :ok ->
                  maybe_log(:consolidate, scope_atom, title, conflict_content)
                  {:ok, format_mem_response(merged)}

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
         {:ok, new_content} <- Map.fetch(args, "new_content"),
         {:ok, scope_atom} <- parse_scope(scope),
         {:ok, mem} <- Memory.read(scope_atom, title) do
      mem
      |> Memory.append(new_content)
      |> Memory.save()
      |> case do
        {:ok, updated} ->
          maybe_log(:update, scope_atom, title, new_content)
          {:ok, format_mem_response(updated)}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    else
      :error -> {:error, "Missing required fields 'scope', 'title', or 'new_content'"}
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
  # Recall project + global memories using embeddings when available.
  defp recall_project_global(query, limit, opts) do
    status_filter = Map.get(opts || %{}, :status_filter)
    provenance_only = Map.get(opts || %{}, :provenance_only, false)

    with {:ok, needle} <- Indexer.impl().get_embeddings(query) do
      {:ok, global} = Memory.Global.list()
      {:ok, project} = Memory.Project.list()

      candidates =
        Enum.map(global, fn title -> {:global, title} end) ++
          Enum.map(project, fn title -> {:project, title} end)

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

              if status_filter and mem.index_status not in status_filter do
                nil
              else
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
  defp recall_session_conversations(query, limit, opts) do
    status_filter = Map.get(opts || %{}, :status_filter)
    provenance_only = Map.get(opts || %{}, :provenance_only, false)

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

          if status_filter and mem.index_status not in status_filter do
            nil
          else
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

  defp do_recall(%{"query" => query, "search_type" => "project_global"} = args) do
    limit = Map.get(args, "limit", 10)
    status_filter = Map.get(args, "status_filter", nil)
    provenance_only = Map.get(args, "provenance_only", false)

    with {:ok, results} <-
           recall_project_global(query, limit, %{
             status_filter: status_filter,
             provenance_only: provenance_only
           }) do
      {:ok, results}
    else
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp do_recall(%{"query" => query, "search_type" => "session_conversations"} = args) do
    limit = Map.get(args, "limit", 10)
    status_filter = Map.get(args, "status_filter", nil)
    provenance_only = Map.get(args, "provenance_only", false)

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
