defmodule Store.DefaultProject.Conversation do
  @file_path "conversation.jsonl"

  def file_path do
    path = Store.DefaultProject.store_path() |> Path.join(@file_path)
    if !File.exists?(path), do: File.write!(path, "")
    path
  end

  def read_messages do
    file_path()
    |> File.stream!()
    |> Stream.reject(&(&1 == ""))
    # Parse each line as JSON
    |> Stream.map(fn line ->
      line
      |> Jason.decode()
      |> case do
        {:ok, msg} -> msg
        {:error, _} -> nil
      end
    end)
    |> Stream.reject(&is_nil/1)
    # Skip timestamp and other non-message entries
    |> Stream.filter(fn
      %{"role" => role} when role in ["user", "assistant", "tool"] -> true
      _ -> false
    end)
  end

  def add_timestamp do
    ts_msg = %{"timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()}

    with {:ok, file} <- File.open(file_path(), [:append]),
         {:ok, ts_json} = Jason.encode(ts_msg) do
      IO.write(file, ts_json <> "\n")
    end
  end

  def add_messages(msgs) do
    with {:ok, file} <- File.open(file_path(), [:append]) do
      msgs
      |> Enum.filter(&(&1["role"] != "system" and &1["role"] != "developer"))
      |> Enum.each(fn msg ->
        with {:ok, json} <- Jason.encode(msg) do
          IO.write(file, json <> "\n")
        end
      end)

      :ok
    end
  end
end
