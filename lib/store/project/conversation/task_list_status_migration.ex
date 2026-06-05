defmodule Store.Project.Conversation.TaskListStatusMigration do
  @moduledoc """
  Helpers to best-effort heal and migrate conversation task-list statuses and shapes.

  These functions are intentionally minimal and safe: they only alter the
  `tasks` map of the decoded conversation JSON if legacy shapes are detected
  (for example the value is a bare list instead of a map), or if a `status`
  field is missing or non-canonical.

  Pure: `heal/1` returns `{repaired_map, changed?}` and does no I/O.
  Persistence is the caller's concern - `Format.parse_v0/2` composes this
  pass with `heal_tool_call_arguments/1` and writes once at the end via
  `Format.persist_heal_as_v1/3` so the two heals can't clobber each other
  on disk.
  """

  @doc """
  Inspect the decoded JSON map for legacy task-list shapes and/or
  non-canonical status values. Returns `{repaired_map, changed?}` - the
  caller decides whether to persist.

  `changed?` is `true` only if at least one list in the tasks map actually
  needed repair. Already-canonical task lists pass through untouched and
  do not flip the flag, so a clean read does not trigger an atomic write.
  """
  @spec heal(map()) :: {map(), boolean()}
  def heal(original_json_map) do
    case Map.get(original_json_map, "tasks") do
      nil ->
        {original_json_map, false}

      tasks_value when is_map(tasks_value) ->
        {healed_tasks, changed?} = heal_tasks_map(tasks_value)

        if changed? do
          {Map.put(original_json_map, "tasks", healed_tasks), true}
        else
          {original_json_map, false}
        end

      _other ->
        # Top-level "tasks" present but not a map - that's malformed; replace
        # with an empty canonical tasks map.
        {Map.put(original_json_map, "tasks", %{}), true}
    end
  end

  defp heal_tasks_map(tasks_value) do
    Enum.reduce(tasks_value, {%{}, false}, fn {list_id, value}, {acc, acc_changed} ->
      {healed_value, list_changed?} = heal_task_list(value)
      {Map.put(acc, list_id, healed_value), acc_changed or list_changed?}
    end)
  end

  defp heal_task_list(value) when is_list(value) do
    # Legacy shape: bare list of tasks -> canonical map.
    {%{"tasks" => value, "description" => nil, "status" => "planning"}, true}
  end

  defp heal_task_list(value) when is_map(value) do
    val = for {kk, vv} <- value, into: %{}, do: {to_string(kk), vv}

    status = normalize_status(Map.get(val, "status"))
    tasks = Map.get(val, "tasks", [])
    desc = Map.get(val, "description")

    healed = %{"tasks" => tasks, "description" => desc, "status" => status}

    # Change detection: if string-keying the input + normalizing status
    # produced something identical to the canonical-shape healed map (no
    # extra keys, status already canonical, etc.) then nothing actually
    # needed repair.
    {healed, val != healed}
  end

  defp heal_task_list(_other) do
    {%{"tasks" => [], "description" => nil, "status" => "planning"}, true}
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
