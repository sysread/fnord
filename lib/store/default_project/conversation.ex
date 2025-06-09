defmodule Store.DefaultProject.Conversation do
  @file_path "conversation.jsonl"

  def file_path do
    path = Store.DefaultProject.store_path() |> Path.join(@file_path)
    if !File.exists?(path), do: File.write!(path, "")
    path
  end

  def read_messages do
    # Filter out non-content messages
    read_file()
    |> Stream.filter(fn
      %{"role" => "assistant"} -> true
      %{"role" => "tool"} -> true
      %{"role" => "user"} -> true
      _ -> false
    end)
  end

  def last_interaction do
    read_file()
    |> Enum.reverse()
    |> Enum.reduce_while([], fn
      %{"timestamp" => _} = msg, acc -> {:halt, [msg | acc]}
      msg, acc -> {:cont, [msg | acc]}
    end)
  end

  def latest_timestamp do
    read_file()
    |> Stream.scan(nil, fn
      %{"timestamp" => ts}, _ -> ts
      _, ts -> ts
    end)
    |> Enum.to_list()
    |> List.last()
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
      |> Stream.filter(&(&1["role"] != "system" and &1["role"] != "developer"))
      |> Stream.each(fn msg ->
        with {:ok, json} <- Jason.encode(msg) do
          IO.write(file, json <> "\n")
        end
      end)
      |> Stream.run()

      :ok
    end
  end

  def replace_messages(msgs) do
    with {:ok, file} <- File.open(file_path(), [:write]) do
      msgs
      |> Enum.filter(&add_message?/1)
      |> Enum.each(fn msg ->
        with {:ok, json} <- Jason.encode(msg) do
          IO.write(file, json <> "\n")
        end
      end)

      :ok
    end
  end

  def read_file do
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
  end

  defp add_message?(%{"role" => "assistant"}), do: true
  defp add_message?(%{"role" => "tool"}), do: true
  defp add_message?(%{"role" => "user"}), do: true
  defp add_message?(%{"timestamp" => _}), do: true
  defp add_message?(%{"type" => "summary"}), do: true
  defp add_message?(_), do: false
end
