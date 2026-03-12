defmodule Skills.Loader do
  @moduledoc """
  Load and validate skill definitions from TOML files.

  This module is responsible for file IO and TOML decoding. It returns
  validated `%Skills.Skill{}` structs and includes file provenance so higher
  layers can explain override behavior.
  """

  require Logger

  @type skill_source :: :user | :project

  @type loaded_skill :: %{
          skill: Skills.Skill.t(),
          name: String.t(),
          source: skill_source,
          path: String.t()
        }

  @type load_error ::
          {:toml_error, path :: String.t(), term()}
          | {:fs_error, path :: String.t(), term()}
          | {:invalid_skill, path :: String.t(), Skills.Skill.decode_error()}
          | {:duplicate_skill_name, String.t(), [String.t()]}

  @doc """
  Load all `*.toml` skill definitions from the given directory.

  Returns a list of loaded skill maps containing the validated skill struct and
  provenance (`source`, `path`).

  Duplicate names within the directory are returned as an error.
  """
  @spec load_dir(String.t(), skill_source) :: {:ok, [loaded_skill]} | {:error, load_error}
  def load_dir(dir, source) when is_binary(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".toml"))
        |> Enum.sort()
        |> Enum.map(&Path.join(dir, &1))
        |> load_files(source)

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:fs_error, dir, reason}}
    end
  end

  @doc """
  Load a list of TOML files as skill definitions.

  Duplicate names within the file set are returned as an error.
  """
  @spec load_files([String.t()], skill_source) :: {:ok, [loaded_skill]} | {:error, load_error}
  def load_files(paths, source) when is_list(paths) do
    with {:ok, loaded} <- do_load_files(paths, source),
         :ok <- ensure_unique_names(loaded) do
      {:ok, loaded}
    end
  end

  defp do_load_files(paths, source) do
    paths
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
      case load_file(path, source) do
        {:ok, loaded} -> {:cont, {:ok, [loaded | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, loaded} -> {:ok, Enum.reverse(loaded)}
      other -> other
    end
  end

  @doc """
  Load a single skill TOML file.
  """
  @spec load_file(String.t(), skill_source) :: {:ok, loaded_skill} | {:error, load_error}
  def load_file(path, source) when is_binary(path) do
    with {:ok, data} <- decode_toml(path),
         {:ok, skill} <- decode_skill(path, data) do
      {:ok, %{skill: skill, name: skill.name, source: source, path: path}}
    end
  end

  defp decode_toml(path) do
    case Fnord.Toml.decode_file(path) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, {:toml_error, path, reason}}
    end
  end

  defp decode_skill(path, data) do
    case Skills.Skill.from_map(data) do
      {:ok, skill, warnings} ->
        Enum.each(warnings, fn
          {:dropped_non_strings, key, values} ->
            Logger.warning(
              "#{path}: non-string values in '#{key}' were ignored: #{inspect(values)}"
            )
        end)

        {:ok, skill}

      {:error, reason} ->
        {:error, {:invalid_skill, path, reason}}
    end
  end

  defp ensure_unique_names(loaded) do
    duplicates =
      loaded
      |> Enum.group_by(& &1.name)
      |> Enum.filter(fn {_name, items} -> length(items) > 1 end)
      |> Enum.map(fn {name, items} -> {name, Enum.map(items, & &1.path)} end)

    case duplicates do
      [] ->
        :ok

      [{name, paths} | _] ->
        {:error, {:duplicate_skill_name, name, paths}}
    end
  end
end
