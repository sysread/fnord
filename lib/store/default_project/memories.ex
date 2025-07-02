defmodule Store.DefaultProject.Memories do
  @file_path "notes.jsonl"

  def file_path do
    path = Store.DefaultProject.store_path() |> Path.join(@file_path)
    if !File.exists?(path), do: File.write!(path, "")
    path
  end

  def build do
    read()
    |> Stream.map(&"#{&1.text} <!id:#{&1.id}!>")
    |> Enum.join("\n")
  end

  def read_lines do
    file_path()
    |> File.stream!()
  end

  def read do
    read_lines()
    |> Stream.reject(&(&1 == ""))
    |> Stream.map(fn line ->
      line
      |> Jason.decode()
      |> case do
        {:ok, memory} -> memory
        {:error, _} -> nil
      end
    end)
    |> Stream.reject(&is_nil/1)
  end

  def create(text) do
    text = String.trim(text)
    id = Uniq.UUID.uuid4()
    ts = DateTime.utc_now() |> DateTime.to_iso8601()

    entry = %{
      "id" => id,
      "created" => ts,
      "updated" => ts,
      "text" => text
    }

    with {:ok, file} <- file_path() |> File.open([:append, {:encoding, :utf8}]),
         {:ok, json} <- Jason.encode(entry) do
      IO.write(file, json <> "\n")
      {:ok, id}
    end
  end

  def update(id, new_text) do
    updated_text =
      read()
      |> Stream.map(fn
        %{"id" => ^id} = memory ->
          memory
          |> Map.put("text", String.trim(new_text))
          |> Map.put("updated", DateTime.utc_now() |> DateTime.to_iso8601())

        memory ->
          memory
      end)
      |> Enum.map(&Jason.encode!/1)
      |> Enum.join("\n")

    file_path()
    |> File.write(updated_text)
    |> case do
      :ok -> {:ok, id}
      other -> other
    end
  end

  def delete(id) do
    updated_text =
      read()
      |> Stream.reject(fn
        %{"id" => ^id} -> true
        _ -> false
      end)
      |> Enum.map(&Jason.encode!/1)
      |> Enum.join("\n")

    file_path()
    |> File.write(updated_text)
    |> case do
      :ok -> {:ok, id}
      other -> other
    end
  end
end
