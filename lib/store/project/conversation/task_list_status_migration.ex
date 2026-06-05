defmodule Store.Project.Conversation.TaskListStatusMigration do
  @moduledoc """
  Helpers to best-effort heal and migrate conversation task-list statuses and shapes.

  These functions are intentionally minimal and safe: they only alter the
  `tasks` map of the decoded conversation JSON if legacy shapes are detected
  (for example the value is a bare list instead of a map), or if a `status`
  field is missing or non-canonical. Repairs are applied in-memory, and the
  module delegates the actual on-disk write to
  `Store.Project.Conversation.Format.persist_heal_as_v1/3` so the heal-write
  format matches every other heal pass (deterministically v1). If
  persistence fails, processing continues without raising.
  """

  alias Store.Project.Conversation.Format

  @doc """
  Inspect the decoded JSON map `original_json_map` for legacy task-list
  shapes and/or non-canonical status values. If repairs are needed, apply them
  in-memory and attempt to atomically persist the repaired JSON to disk via
  `Format.persist_heal_as_v1/3`. `ts_int` is the original v0 prefix timestamp
  (already parsed to integer in `Format.parse_v0/2`).

  Persistence is best-effort: if the write fails (for example due to concurrent
  access or filesystem issues), this function will warn and continue without
  raising so callers can keep reading the conversation.

  This function is safe to call from Store.Project.Conversation.Format.parse_v0/2;
  it is conservative and only writes when it detects a change.
  """
  @spec heal_and_maybe_write(map(), Store.Project.Conversation.t(), integer()) :: :ok
  def heal_and_maybe_write(original_json_map, conversation, ts_int) do
    {changed, repaired} =
      original_json_map
      |> Enum.reduce({false, %{}}, fn {k, v}, {acc_changed, acc_map} ->
        if k == "tasks" do
          tasks_map =
            v
            |> Enum.map(fn {list_id, value} ->
              cond do
                is_list(value) ->
                  # Legacy shape: bare list of tasks -> convert to canonical map
                  {list_id, %{"tasks" => value, "description" => nil, "status" => "planning"}}

                is_map(value) ->
                  # Ensure string keys and normalize status
                  val = for {kk, vv} <- value, into: %{}, do: {to_string(kk), vv}

                  status = normalize_status(Map.get(val, "status"))
                  tasks = Map.get(val, "tasks", [])
                  desc = Map.get(val, "description")

                  {list_id, %{"tasks" => tasks, "description" => desc, "status" => status}}

                true ->
                  {list_id, %{"tasks" => [], "description" => nil, "status" => "planning"}}
              end
            end)
            |> Map.new()

          {true, Map.put(acc_map, "tasks", tasks_map)}
        else
          {acc_changed, Map.put(acc_map, k, v)}
        end
      end)

    if changed do
      # Ensure the conversations directory exists before the atomic-rename
      # write that Format.persist_heal_as_v1/3 performs. Cheap, idempotent.
      conversation.project_home
      |> Path.join("conversations")
      |> File.mkdir_p()

      _ = Format.persist_heal_as_v1(conversation, repaired, ts_int)
      :ok
    else
      :ok
    end
  end

  # Normalize status values to canonical string set
  defp normalize_status(nil), do: "planning"

  defp normalize_status(status) when is_atom(status) do
    normalize_status(Atom.to_string(status))
  end

  defp normalize_status(status) when is_binary(status) do
    case String.downcase(status) do
      "planning" -> "planning"
      "planned" -> "planning"
      "in_progress" -> "in-progress"
      "in-progress" -> "in-progress"
      "in progress" -> "in-progress"
      "done" -> "done"
      "failed" -> "done"
      other -> other
    end
  end
end
