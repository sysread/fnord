defmodule Store.Project.Samskara do
  @moduledoc """
  Per-project storage for samskara records. Each record lives as a single JSON
  file under `<project.store_path>/samskaras/<id>.json`.

  Impressions (consolidated records) are stored alongside originals; they are
  distinguished by the `impression` flag on the record JSON.
  """

  alias Store.Project.Samskara.Record

  @store_dir "samskaras"

  @spec dir(Store.Project.t()) :: String.t()
  def dir(%Store.Project{store_path: store_path}) do
    Path.join(store_path, @store_dir)
  end

  @spec ensure_dir!(Store.Project.t()) :: :ok
  def ensure_dir!(project) do
    project |> dir() |> File.mkdir_p!()
    :ok
  end

  @spec record_path(Store.Project.t(), binary) :: String.t()
  def record_path(project, id) when is_binary(id) do
    project |> dir() |> Path.join(id <> ".json")
  end

  @spec list(Store.Project.t()) :: [Record.t()]
  def list(project) do
    case list_files(project) do
      [] ->
        []

      paths ->
        paths
        |> Enum.map(&read_file/1)
        |> Enum.flat_map(fn
          {:ok, record} -> [record]
          _ -> []
        end)
        |> Enum.sort_by(& &1.minted_at, {:desc, DateTime})
    end
  end

  @spec list_active(Store.Project.t()) :: [Record.t()]
  def list_active(project) do
    project
    |> list()
    |> Enum.filter(fn r -> not r.superseded end)
  end

  @spec list_unconsolidated(Store.Project.t()) :: [Record.t()]
  def list_unconsolidated(project) do
    project
    |> list()
    |> Enum.filter(fn r -> is_nil(r.consolidated_into) and not r.impression? end)
  end

  @spec count(Store.Project.t()) :: non_neg_integer()
  def count(project), do: project |> list_files() |> length()

  @spec get(Store.Project.t(), binary) :: {:ok, Record.t()} | {:error, :not_found | term}
  def get(project, id) when is_binary(id) do
    path = record_path(project, id)

    if File.exists?(path) do
      read_file(path)
    else
      {:error, :not_found}
    end
  end

  @spec write(Store.Project.t(), Record.t()) :: {:ok, Record.t()} | {:error, term}
  def write(project, %Record{} = record) do
    ensure_dir!(project)
    path = record_path(project, record.id)

    with {:ok, json} <- SafeJson.encode(Record.to_json_map(record)),
         :ok <- File.write(path, json) do
      {:ok, record}
    end
  end

  @spec delete(Store.Project.t(), binary) :: :ok | {:error, term}
  def delete(project, id) when is_binary(id) do
    path = record_path(project, id)

    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      other -> other
    end
  end

  @spec mark_consolidated(Store.Project.t(), [binary], binary) :: :ok
  def mark_consolidated(project, source_ids, impression_id) when is_list(source_ids) do
    Enum.each(source_ids, fn id ->
      case get(project, id) do
        {:ok, record} ->
          updated = %Record{record | consolidated_into: impression_id, superseded: true}
          write(project, updated)

        _ ->
          :ok
      end
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------
  defp list_files(project) do
    dir = dir(project)

    if File.dir?(dir) do
      dir |> Path.join("*.json") |> Path.wildcard()
    else
      []
    end
  end

  defp read_file(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, data} <- SafeJson.decode(contents) do
      {:ok, Record.from_json_map(data)}
    end
  end
end
