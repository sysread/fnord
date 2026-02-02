defmodule DockerSandbox.Store do
  @moduledoc false

  alias Store.Project
  alias DockerSandbox.BaseImage
  alias FileLock

  @index_file "index.json"
  @meta_file "meta.json"
  @df_file "dockerfile"

  @spec dockerfile_prefix() :: String.t()
  defp dockerfile_prefix do
    "# fnord-docker-sandbox\n# ---\nFROM #{BaseImage.tag()}\n"
  end

  @spec root_path(Project.t()) :: String.t()
  def root_path(%Project{store_path: sp}) do
    Path.join([sp, "tools", "sandboxes"])
  end

  @spec list(Project.t()) :: [
          %{name: String.t(), description: String.t(), updated_at: String.t()}
        ]
  def list(proj) do
    root = root_path(proj)
    idx = Path.join(root, @index_file)

    case File.read(idx) do
      {:ok, content} ->
        content
        |> Jason.decode!()
        |> Enum.map(fn %{"name" => name, "description" => desc, "updated_at" => updated_at} ->
          %{name: name, description: desc, updated_at: updated_at}
        end)

      _ ->
        []
    end
  end

  @type sandbox_map :: %{
          required(String.t()) => term()
        }

  @spec get(Project.t(), String.t()) :: {:ok, sandbox_map()} | {:error, :not_found}
  def get(proj, name) do
    if not valid_slug?(name) do
      {:error, :not_found}
    else
      root = root_path(proj)
      sandbox_dir = Path.join(root, name)
      meta_file = Path.join(sandbox_dir, @meta_file)
      df_file = Path.join(sandbox_dir, @df_file)

      with {:ok, meta_content} <- File.read(meta_file),
           {:ok, dockerfile_content} <- File.read(df_file) do
        meta_map = Jason.decode!(meta_content)
        user_body = String.replace_prefix(dockerfile_content, dockerfile_prefix(), "")

        {:ok,
         %{
           "name" => meta_map["name"],
           "description" => meta_map["description"],
           "dockerfile_body" => user_body,
           "default_run_args" => meta_map["default_run_args"] || []
         }}
      else
        _ ->
          {:error, :not_found}
      end
    end
  end

  @spec put(Project.t(), %{
          name: String.t(),
          description: String.t(),
          dockerfile_body: String.t(),
          default_run_args: [term()]
        }) ::
          {:ok, map()} | {:error, term()}
  def put(proj, %{
        name: name,
        description: desc,
        dockerfile_body: user_body,
        default_run_args: run_args
      }) do
    if not valid_slug?(name) do
      {:error, :invalid_name}
    else
      root = root_path(proj)
      File.mkdir_p!(root)
      lock = Path.join(root, ".lock")

      case FileLock.with_lock(lock, fn ->
             # Ensure sandbox directory exists
             sandbox_dir = Path.join(root, name)
             File.mkdir_p!(sandbox_dir)

             # Write meta.json atomically
             meta = %{"name" => name, "description" => desc, "default_run_args" => run_args}
             Settings.write_atomic!(Path.join(sandbox_dir, @meta_file), Jason.encode!(meta))

             # Write dockerfile atomically
             Settings.write_atomic!(
               Path.join(sandbox_dir, @df_file),
               dockerfile_prefix() <> user_body
             )

             # Update index.json atomically
             idx = Path.join(root, @index_file)
             entries = list(proj)

             new_entry = %{
               "name" => name,
               "description" => desc,
               "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
             }

             existing =
               entries
               |> Enum.reject(&(&1.name == name))
               |> Enum.map(fn e ->
                 %{"name" => e.name, "description" => e.description, "updated_at" => e.updated_at}
               end)

             entries_to_write = [new_entry | existing]
             Settings.write_atomic!(idx, Jason.encode!(entries_to_write))

             :ok
           end) do
        {:ok, :ok} ->
          get(proj, name)

        {:error, reason} ->
          {:error, reason}

        {:callback_error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec delete(Project.t(), String.t()) :: :ok | {:error, :not_found}
  def delete(proj, name) do
    if not valid_slug?(name) do
      {:error, :not_found}
    else
      root = root_path(proj)
      sandbox_dir = Path.join(root, name)

      if not File.dir?(sandbox_dir) do
        {:error, :not_found}
      else
        File.mkdir_p!(root)
        lock = Path.join(root, ".lock")

        case FileLock.with_lock(lock, fn ->
               File.rm_rf!(sandbox_dir)

               idx = Path.join(root, @index_file)

               entries =
                 list(proj)
                 |> Enum.reject(&(&1.name == name))
                 |> Enum.map(fn e ->
                   %{
                     "name" => e.name,
                     "description" => e.description,
                     "updated_at" => e.updated_at
                   }
                 end)

               Settings.write_atomic!(idx, Jason.encode!(entries))

               :ok
             end) do
          {:ok, :ok} -> :ok
          {:error, reason} -> {:error, reason}
          {:callback_error, reason} -> {:error, reason}
        end
      end
    end
  end

  defp valid_slug?(slug) when is_binary(slug) do
    Regex.match?(~r/^[A-Za-z0-9_-]+$/, slug)
  end

  defp valid_slug?(_), do: false
end
