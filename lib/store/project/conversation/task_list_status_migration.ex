defmodule Store.Project.Conversation.TaskListStatusMigration do
  @moduledoc """
  Helpers to best-effort heal and migrate conversation task-list statuses and shapes.

  These functions are intentionally minimal and safe: they only alter the
  `tasks` map of the decoded conversation JSON if legacy shapes are detected
  (for example the value is a bare list instead of a map), or if a `status`
  field is missing or non-canonical. Repairs are applied in-memory, and the
  module attempts an atomic write of the repaired JSON back to disk, but if
  persistence fails, processing continues without raising. The timestamp prefix
  used by the Store.Project.Conversation format is preserved.
  """

  @doc """
  Inspect the decoded JSON map `original_json_map` for legacy task-list
  shapes and/or non-canonical status values. If repairs are needed, apply them
  in-memory and attempt to atomically persist the repaired JSON to disk using
  the provided `conversation` and the original `timestamp_str` (the unix
  timestamp string prefix).

  Persistence is best-effort: if the write fails (for example due to concurrent
  access or filesystem issues), this function will warn and continue without
  raising so callers can keep reading the conversation.

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
      case write_file_with_ts(conversation, timestamp_str, repaired) do
        :ok ->
          :ok

        {:error, reason} ->
          UI.warn(
            "Could not persist healed tasks for conversation #{conversation.id}: #{inspect(reason)}"
          )

          :ok
      end
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

  @spec write_file_with_ts(Store.Project.Conversation.t(), String.t(), map()) ::
          :ok | {:error, term()}
  defp write_file_with_ts(conversation, timestamp_str, data_map) do
    conversation.project_home
    |> Path.join("conversations")
    |> File.mkdir_p()

    tmp = conversation.store_path <> ".tmp"

    with {:ok, json} <- SafeJson.encode(data_map),
         :ok <- File.write(tmp, "#{timestamp_str}:" <> json),
         :ok <- safe_rename(tmp, conversation.store_path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, reason}
    end
  end

  @spec safe_rename(String.t(), String.t()) :: :ok | {:error, term()}
  defp safe_rename(tmp, dest) do
    case File.rename(tmp, dest) do
      :ok ->
        :ok

      {:error, :enoent} ->
        if File.exists?(tmp) do
          {:error, :dest_missing}
        else
          {:error, :tmp_missing}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
