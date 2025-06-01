defmodule Store.DefaultProject.Prompt do
  @file_path "prompt.jsonl"

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

  def read do
    file_path()
    |> File.stream!()
    |> Stream.reject(&(&1 == ""))
    |> Stream.map(fn line ->
      line
      |> Jason.decode()
      |> case do
        {:ok, prompt} -> prompt
        {:error, _} -> nil
      end
    end)
    |> Stream.reject(&is_nil/1)
  end

  def create(text) do
    id = Uniq.UUID.uuid4()
    prompt = String.trim(text)

    file_path()
    |> File.open([:append])
    |> case do
      {:ok, file} ->
        ts = DateTime.utc_now() |> DateTime.to_iso8601()

        %{
          "id" => id,
          "created" => ts,
          "updated" => ts,
          "text" => prompt
        }
        |> Jason.encode()
        |> case do
          {:ok, json} ->
            IO.write(file, json <> "\n")
            {:ok, id}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def update(id, new_text) do
    read()
    |> Stream.map(fn
      %{"id" => ^id} = prompt ->
        prompt
        |> Map.put("text", String.trim(new_text))
        |> Map.put("updated", DateTime.utc_now() |> DateTime.to_iso8601())

      prompt ->
        prompt
    end)
    |> Enum.map(&Jason.encode!/1)
    |> Enum.join("\n")
    |> File.write(file_path())
  end

  def delete(id) do
    read()
    |> Stream.reject(fn
      %{"id" => ^id} -> true
      _ -> false
    end)
    |> Enum.map(&Jason.encode!/1)
    |> Enum.join("\n")
    |> File.write(file_path())
  end
end
