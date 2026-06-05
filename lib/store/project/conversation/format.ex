defmodule Store.Project.Conversation.Format do
  @moduledoc """
  Format detection and parsing for conversation files. Two formats coexist:

    * **v0** - the legacy timestamp-prefixed shape: `<unix_ts>:<json>`. The
      `<unix_ts>` is a numeric prefix that lets `list/1` and `timestamp/1`
      sort conversations without parsing the JSON. Read-only at this point -
      no code path emits v0; older files still on disk are read transparently.

    * **v1** - pure JSON. The top-level object carries `version: 1`,
      `timestamp: <unix_int>`, and the same `messages`/`metadata`/`memory`/
      `tasks` keys v0 has. Current on-the-wire shape; what every writer
      emits.

  ## Why this module exists

  All worktrees in a project share `.fnord/projects/<project>/conversations/`.
  Background services (MemoryIndexer, ConversationIndexer) in any worktree can
  read any conversation file. If one build starts emitting v1 files while
  another build only reads v0, the older build flags every v1 file as corrupt
  and skips it - data loss in practice.

  The two-step rollout that got us here:

    1. **Phase 1b** - shipped a build whose readers understand BOTH v0 and
       v1, while the writer continued to emit v0. Reader-tolerant +
       writer-conservative.
    2. **Phase 2c** - flipped the writer to v1. Older Phase-1b readers parse
       the new files unchanged. Writer-aggressive.

  This module is now at Phase 2c. v1 is the canonical on-disk format; v0 is a
  read-only legacy shape that still appears in files written before the
  flip.

  ## Heal-on-read (and forward migration)

  v0 files in the wild may carry legacy shapes from earlier code paths:

    * `tasks` map with bare lists or non-canonical statuses - healed by
      `Store.Project.Conversation.TaskListStatusMigration`.
    * `tool_calls[].function.arguments` stored as decoded maps instead of
      JSON strings - re-encoded by `heal_tool_call_arguments/3` here. (See
      engram memory "Conversation file corruption - responses branch tool
      arguments" for the atom-table backstory.)

  When either heal pass triggers on a v0 file, the repaired content is
  persisted **as v1** via `write_v1_blob/2`, not back as v0. Two reasons:

    1. The writer is at v1; emitting fresh v0 would create new legacy files.
    2. Older builds without the heal pass would silently mis-parse the
       healed-in-place v0 shape; a v1 file at least surfaces as a clean
       format-version skip rather than a corrupt decode.

  This means stale v0 files migrate forward incrementally as they are
  touched. Untouched v0 files stay v0 indefinitely (read-only paths don't
  rewrite them).

  v1 files don't carry the legacy shapes and skip the heal passes entirely.
  """

  alias Store.Project.Conversation
  alias Store.Project.Conversation.TaskListStatusMigration

  @type version :: :v0 | :v1

  @doc """
  Detect the format of a raw conversation file's contents. v0 is identified
  by a `\\d+:` prefix, v1 by a JSON object opener (with optional leading
  whitespace).
  """
  @spec detect(binary()) :: {:ok, version()} | {:error, :unrecognized}
  def detect(content) when is_binary(content) do
    cond do
      Regex.match?(~r/^\d+:/, content) -> {:ok, :v0}
      String.starts_with?(String.trim_leading(content), "{") -> {:ok, :v1}
      true -> {:error, :unrecognized}
    end
  end

  @doc """
  Read a conversation from disk, dispatch to the right parser, apply heal
  passes for v0 files, and return the canonical in-memory data shape that
  `Store.Project.Conversation.read/1` callers expect.
  """
  @spec read(Conversation.t()) :: {:ok, Conversation.data()} | {:error, any()}
  def read(conversation) do
    with {:ok, contents} <- File.read(conversation.store_path),
         {:ok, version} <- detect(contents) do
      case version do
        :v0 -> parse_v0(contents, conversation)
        :v1 -> parse_v1(contents, conversation)
      end
    else
      {:error, :unrecognized} -> {:error, {:corrupt_conversation, :unrecognized_format}}
      other -> other
    end
  rescue
    e ->
      UI.warn("Skipping corrupt conversation file", conversation.store_path)
      {:error, {:corrupt_conversation, Exception.message(e)}}
  end

  @doc """
  Extract just the timestamp from a raw file contents string. v0 reads only
  the prefix (cheap); v1 has to decode the whole JSON object (less cheap, but
  paid only once a v1 file is encountered).
  """
  @spec timestamp_of(binary()) :: {:ok, DateTime.t()} | {:error, any()}
  def timestamp_of(contents) when is_binary(contents) do
    case detect(contents) do
      {:ok, :v0} ->
        with [ts_str, _rest] <- String.split(contents, ":", parts: 2),
             {int, ""} <- Integer.parse(ts_str),
             {:ok, ts} <- DateTime.from_unix(int) do
          {:ok, ts}
        else
          _ -> {:error, :invalid_timestamp}
        end

      {:ok, :v1} ->
        with {:ok, data} <- SafeJson.decode(contents),
             ts when is_integer(ts) <- Map.get(data, "timestamp"),
             {:ok, ts} <- DateTime.from_unix(ts) do
          {:ok, ts}
        else
          _ -> {:error, :invalid_timestamp}
        end

      err ->
        err
    end
  end

  # --------------------------------------------------------------------------
  # v0 parser - the legacy shape that's been in use since conversations
  # were first persisted. Splits the `<ts>:<json>` prefix, applies the
  # task-list and tool-call-arguments heal passes (which may persist
  # repairs back to disk), then converts the JSON map into the canonical
  # in-memory `Conversation.data` shape.
  # --------------------------------------------------------------------------

  defp parse_v0(contents, conversation) do
    with [timestamp_str, json] <- String.split(contents, ":", parts: 2),
         {ts_int, ""} <- Integer.parse(timestamp_str),
         {:ok, timestamp} <- DateTime.from_unix(ts_int),
         {:ok, raw} <- SafeJson.decode(json) do
      # Compose both heal passes as pure functions (raw -> {repaired, changed?}),
      # THEN persist once if anything changed. Two reasons this composition
      # matters:
      #
      #   1. If both heals fire and each persists independently, the second
      #      write builds its JSON from data that doesn't include the first
      #      heal's repair - so the second write clobbers the first on disk.
      #   2. Single end-of-read write is atomic: either both repairs persist
      #      or neither does (e.g. on BEAM crash mid-heal). No half-healed
      #      file on disk.
      #
      # On-disk format after any heal is deterministically v1 via
      # persist_heal_as_v1/3.
      {repaired_tasks, tasks_changed?} = TaskListStatusMigration.heal(raw)
      {repaired, tools_changed?} = heal_tool_call_arguments(repaired_tasks)

      if tasks_changed? or tools_changed? do
        _ = persist_heal_as_v1(conversation, repaired, ts_int)
      end

      {:ok, finalize(repaired, timestamp)}
    else
      _ -> {:error, {:corrupt_conversation, :v0_parse_failed}}
    end
  end

  # --------------------------------------------------------------------------
  # v1 parser - pure JSON object with `version: 1` and `timestamp: <unix>`
  # at the top level. v1 files don't carry the v0 legacy shapes, so the
  # heal passes are not applied. (If a v1 file is ever observed with a
  # stale shape, the existing pattern is to add an explicit migrator in
  # this namespace rather than re-running the v0 heals.)
  # --------------------------------------------------------------------------

  defp parse_v1(contents, _conversation) do
    with {:ok, raw} <- SafeJson.decode(contents),
         ts_int when is_integer(ts_int) <- Map.get(raw, "timestamp"),
         {:ok, timestamp} <- DateTime.from_unix(ts_int) do
      {:ok, finalize(raw, timestamp)}
    else
      _ -> {:error, {:corrupt_conversation, :v1_parse_failed}}
    end
  end

  # --------------------------------------------------------------------------
  # Common finalization. Takes the raw JSON-decoded map (string keys
  # throughout) and the parsed timestamp, returns the canonical
  # `Conversation.data` shape: messages with atom keys, metadata with atom
  # keys, Memory structs, Task structs grouped by list_id.
  # --------------------------------------------------------------------------

  defp finalize(raw, timestamp) do
    msgs =
      raw
      |> Map.get("messages", [])
      |> Enum.flat_map(fn m -> List.wrap(hydrate_message(m)) end)

    metadata =
      raw
      |> Map.get("metadata", %{})
      |> Util.string_keys_to_atoms()

    memories =
      raw
      |> Map.get("memory", [])
      |> Util.string_keys_to_atoms()
      |> Enum.map(&Memory.new_from_map/1)

    tasks = finalize_tasks(raw)

    %{
      timestamp: timestamp,
      messages: msgs,
      metadata: metadata,
      memory: memories,
      tasks: tasks
    }
  end

  # Convert a raw message map (string-keyed, post-JSON-decode) into an
  # AI.Message struct. Tolerates:
  #
  #   * The new struct-serialized shape: %{"role" => ..., "content" => ...}
  #     for User/Assistant/System; %{"type" => "function_call", ...} and
  #     %{"type" => "function_call_output", ...} for tool requests/responses.
  #   * The legacy chat-completions shape with a tool-role message
  #     (%{"role" => "tool", "tool_call_id" => ..., "content" => ...}) which
  #     becomes a FunctionCallOutput.
  #   * The legacy assistant-with-tool_calls shape, which fans out: any
  #     assistant message carrying tool_calls is replaced by N FunctionCall
  #     structs (or N+1 if it also has prose content).
  #
  # The fan-out is why this helper can return a list. finalize/2 flattens.
  defp hydrate_message(raw) when is_map(raw) do
    type = Map.get(raw, "type") || Map.get(raw, :type)
    role = Map.get(raw, "role") || Map.get(raw, :role)
    tool_calls = Map.get(raw, "tool_calls") || Map.get(raw, :tool_calls)

    cond do
      type == "function_call" ->
        AI.Message.FunctionCall.from_map(raw)

      type == "function_call_output" ->
        AI.Message.FunctionCallOutput.from_map(raw)

      type == "reasoning" ->
        AI.Message.Reasoning.from_map(raw)

      role == "tool" ->
        AI.Message.FunctionCallOutput.from_map(raw)

      role == "assistant" and is_list(tool_calls) ->
        hydrate_legacy_assistant_with_tool_calls(raw, tool_calls)

      role == "assistant" ->
        AI.Message.Assistant.from_map(raw)

      role == "user" ->
        AI.Message.User.from_map(raw)

      role in ["system", "developer"] ->
        AI.Message.System.from_map(raw)

      true ->
        raw
    end
  end

  defp hydrate_message(other), do: other

  # v0 files store tool call requests nested inside an assistant message.
  # Each becomes its own FunctionCall struct in the hydrated list. Any prose
  # content on the assistant message is preserved as a leading Assistant
  # struct so the ordering looks chronologically right in transcripts.
  defp hydrate_legacy_assistant_with_tool_calls(raw, tool_calls) do
    prose = Map.get(raw, "content") || Map.get(raw, :content)

    leading =
      if is_binary(prose) and prose != "" do
        [AI.Message.Assistant.new(prose)]
      else
        []
      end

    calls =
      Enum.map(tool_calls, fn tc ->
        id = Map.get(tc, "id") || Map.get(tc, :id) || ""
        function = Map.get(tc, "function") || Map.get(tc, :function) || %{}
        name = Map.get(function, "name") || Map.get(function, :name) || ""
        args = Map.get(function, "arguments") || Map.get(function, :arguments) || "{}"

        AI.Message.FunctionCall.from_map(%{
          type: "function_call",
          call_id: id,
          name: name,
          arguments: args
        })
      end)

    leading ++ calls
  end

  # Normalize a `tasks` map to the canonical `%{list_id => %{description:,
  # tasks: [Task.t()]}}` shape. Tolerates both the legacy bare-list shape
  # and the newer map-with-description shape.
  defp finalize_tasks(raw) do
    raw
    |> Map.get("tasks", %{})
    |> Enum.map(fn {list_id, value} ->
      {raw_tasks, desc} =
        cond do
          is_list(value) ->
            {value, nil}

          is_map(value) ->
            val = Util.string_keys_to_atoms(value)
            {Map.get(val, :tasks, []), Map.get(val, :description)}

          true ->
            {[], nil}
        end

      tasks_list =
        raw_tasks
        |> Util.string_keys_to_atoms()
        |> Enum.map(fn %{id: task_id, data: data} = task_data ->
          opts =
            task_data
            |> Map.drop([:id, :data])
            |> Keyword.new()

          opts =
            case Keyword.get(opts, :outcome) do
              outcome when not is_nil(outcome) ->
                Keyword.put(opts, :outcome, Services.Task.Util.normalize_outcome(outcome))

              _ ->
                opts
            end

          Services.Task.new_task(task_id, data, opts)
        end)

      {list_id, %{description: desc, tasks: tasks_list}}
    end)
    |> Map.new()
  end

  # --------------------------------------------------------------------------
  # Tool-call arguments heal pass. v0 files can carry decoded-map arguments
  # from a removed code path; re-encode and persist before the rest of the
  # pipeline turns string keys into atoms. See the module doc.
  # --------------------------------------------------------------------------

  # Pure heal: takes the decoded v0 map, returns {repaired_map, changed?}.
  # Persistence is the caller's concern - parse_v0/2 composes this with the
  # other heal passes and writes once at the end so the heals can't clobber
  # each other on disk.
  @spec heal_tool_call_arguments(map()) :: {map(), boolean()}
  defp heal_tool_call_arguments(data) do
    messages = Map.get(data, "messages", [])

    {healed_messages, changed} =
      Enum.map_reduce(messages, false, fn msg, changed ->
        case Map.get(msg, "tool_calls") do
          tool_calls when is_list(tool_calls) ->
            {healed_tcs, tc_changed} =
              Enum.map_reduce(tool_calls, false, fn tc, tc_changed ->
                function = Map.get(tc, "function", %{})
                arguments = Map.get(function, "arguments")

                if is_map(arguments) do
                  case SafeJson.encode(arguments) do
                    {:ok, json_str} ->
                      healed_fn = Map.put(function, "arguments", json_str)
                      {Map.put(tc, "function", healed_fn), true}

                    {:error, _} ->
                      {tc, tc_changed}
                  end
                else
                  {tc, tc_changed}
                end
              end)

            if tc_changed do
              {Map.put(msg, "tool_calls", healed_tcs), true}
            else
              {msg, changed}
            end

          _ ->
            {msg, changed}
        end
      end)

    if changed do
      {Map.put(data, "messages", healed_messages), true}
    else
      {data, false}
    end
  end

  @doc """
  Shared heal-persistence path: write a healed v0 conversation back as v1.

  Used by both heal passes (`heal_tool_call_arguments/3` in this module and
  `TaskListStatusMigration.heal_and_maybe_write/3`) so the on-disk format
  after any heal is deterministically v1 - not "whichever pass happened to
  fire last."

  Why heal forward to v1 rather than re-emit v0:
    1. The writer is at v1; emitting fresh v0 would create new legacy files.
    2. Older builds without the heal pass would silently mis-parse a healed
       v0 file; a v1 file at least surfaces as :corrupt_conversation in
       those builds so it gets skipped rather than mis-interpreted.

  Errors are warnings, not raises - the caller's in-memory copy is already
  healed, and a failed persist just means the next read will heal again.
  """
  @spec persist_heal_as_v1(Conversation.t(), map(), integer()) :: :ok | {:error, any()}
  def persist_heal_as_v1(conversation, data, ts_int) when is_integer(ts_int) do
    case write_v1_blob(data, ts_int) do
      {:ok, json} -> atomic_write(conversation, json, :heal)
      {:error, reason} -> heal_warn(conversation, reason)
    end
  end

  # --------------------------------------------------------------------------
  # v1 writer
  # --------------------------------------------------------------------------

  @doc """
  Write a conversation as a v1 file. The on-disk shape is pure JSON with
  `version: 1` and a top-level integer `timestamp` field; the legacy
  `<unix_ts>:<json>` prefix is gone.

  `data` is the canonical in-memory map (`%{messages:, metadata:, memory:,
  tasks:}`) - the same shape `Conversation.read/1` returns. Messages are
  encoded via their `Jason.Encoder` impls (every AI.Message struct derives
  it); other fields encode as plain maps.
  """
  @spec write(Conversation.t(), map(), integer()) :: :ok | {:error, any()}
  def write(conversation, data, timestamp) when is_integer(timestamp) do
    with {:ok, json} <- write_v1_blob(data, timestamp) do
      atomic_write(conversation, json, :write)
    end
  end

  defp write_v1_blob(data, timestamp) when is_integer(timestamp) do
    data
    |> normalize_for_wire()
    |> Map.put(:version, 1)
    |> Map.put(:timestamp, timestamp)
    |> SafeJson.encode()
  end

  # Strip any in-memory cruft that doesn't belong on the wire. Today the
  # canonical map's keys are all directly Jason-encodable (messages contain
  # AI.Message structs with Jason.Encoder, memory is a list of Memory structs,
  # tasks is a map of task lists). Nothing to do yet - the function exists as
  # a single chokepoint for any future scrubbing without re-touching the
  # write path.
  defp normalize_for_wire(data) when is_map(data), do: data

  defp atomic_write(conversation, json, source) do
    tmp = conversation.store_path <> ".tmp"

    with :ok <- File.write(tmp, json),
         :ok <- File.rename(tmp, conversation.store_path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)

        case source do
          :heal -> heal_warn(conversation, reason)
          :write -> {:error, reason}
        end
    end
  end

  defp heal_warn(conversation, reason) do
    UI.warn(
      "Could not persist healed tool arguments for conversation #{conversation.id}: #{inspect(reason)}"
    )
  end
end
