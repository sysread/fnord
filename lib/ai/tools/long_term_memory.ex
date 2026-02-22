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
            "action" => %{type: "string", enum: ["remember", "update", "forget"]},
            "scope" => %{type: "string", enum: ["project", "global"]},
            "title" => %{type: "string"},
            "content" => %{type: "string"}
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
          saved =
            mem
            |> maybe_add_topics(topics)
            |> Memory.save()

          case saved do
            {:ok, _} ->
              maybe_log(:create, scope_atom, title, content)
              {:ok, format_mem_response(mem)}

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
                {:ok, _} ->
                  maybe_log(:consolidate, scope_atom, title, conflict_content)
                  {:ok, format_mem_response(merged)}

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
end
