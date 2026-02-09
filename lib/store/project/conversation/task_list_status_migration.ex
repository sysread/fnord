defmodule Store.Project.Conversation.TaskListStatusMigration do
  @moduledoc """
  Helpers to heal and migrate conversation task-list statuses and shapes.

  These functions are intentionally minimal and safe: they only alter the
  `tasks` map of the decoded conversation JSON if legacy shapes are detected
  (for example the value is a bare list instead of a map), or if a `status`
  field is missing or non-canonical. The migration is performed in-place via
  an atomic write that preserves the original timestamp prefix used by the
  Store.Project.Conversation format.
  """

  @doc """
  Inspect the decoded JSON map `original_json_map` for legacy task-list
  shapes and/or non-canonical status values. If repairs are needed, atomically
  write the repaired JSON back to disk using the provided `conversation` and
  the original `timestamp_str` (which is the unix timestamp string prefix).

  This function is safe to call from Store.Project.Conversation.read/1; it is
  conservative and only writes when it detects a change.
  """
  @spec heal_and_maybe_write(map(), Store.Project.Conversation.t(), String.t()) :: :ok
  def heal_and_maybe_write(original_json_map, conversation, timestamp_str) do
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
      write_file_with_ts(conversation, timestamp_str, repaired)
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

  defp write_file_with_ts(conversation, timestamp_str, data_map) do
    conversation.project_home
    |> Path.join("conversations")
    |> File.mkdir_p()

    json = Jason.encode!(data_map)
    tmp = conversation.store_path <> ".tmp"
    File.write!(tmp, "#{timestamp_str}:" <> json)
    File.rename!(tmp, conversation.store_path)
  end
end
