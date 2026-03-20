defmodule Settings.Validation do
  @moduledoc """
  Reads and normalizes project-scoped validation settings.

  Validation rules live under a project's `validation` key in `settings.json`.
  Each rule maps one or more project-relative path globs to a command string
  that should be executed when matching files change.
  """

  @type rule :: %{
          path_globs: [String.t()],
          command: String.t()
        }

  @doc """
  Returns the normalized validation rules for the currently selected project.
  """
  @spec list() :: [rule()]
  def list() do
    case Settings.get_selected_project() do
      {:ok, project_name} -> list(project_name)
      {:error, :project_not_set} -> []
    end
  end

  @doc """
  Returns the normalized validation rules for the named project.
  """
  @spec list(String.t()) :: [rule()]
  def list(project_name) when is_binary(project_name) do
    Settings.new()
    |> Settings.get_project_data(project_name)
    |> get_rules()
    |> normalize_rules()
  end

  @doc """
  Returns true when the current project has at least one valid validation rule.
  """
  @spec configured?() :: boolean
  def configured?() do
    list() != []
  end

  @doc """
  Returns true when the named project has at least one valid validation rule.
  """
  @spec configured?(String.t()) :: boolean
  def configured?(project_name) when is_binary(project_name) do
    list(project_name) != []
  end

  @doc """
  Adds a normalized validation rule to the currently selected project so the
  active project's validation command set includes another file-matching rule.
  """
  @spec add_rule(String.t(), String.t() | [String.t()]) ::
          {:ok, [rule()]} | {:error, :invalid_rule | :project_not_set}
  def add_rule(command, path_globs) do
    case Settings.get_selected_project() do
      {:ok, project_name} -> add_rule(project_name, command, path_globs)
      {:error, :project_not_set} -> {:error, :project_not_set}
    end
  end

  @doc """
  Adds a normalized validation rule to the named project as part of managing
  the project's persisted validation rule set.
  """
  @spec add_rule(String.t(), String.t(), String.t() | [String.t()]) ::
          {:ok, [rule()]} | {:error, :invalid_rule | :project_not_found}
  def add_rule(project_name, command, path_globs)
      when is_binary(project_name) and is_binary(command) do
    case normalize_candidate_rule(command, path_globs) do
      nil ->
        {:error, :invalid_rule}

      rule ->
        update_rules(project_name, fn rules ->
          {:ok, rules ++ [rule]}
        end)
    end
  end

  @doc """
  Removes the validation rule at the given 1-based index from the currently
  selected project so the active project's validation rule set no longer
  includes that entry.
  """
  @spec remove_rule(integer()) ::
          {:ok, [rule()]} | {:error, :invalid_index | :project_not_set | :project_not_found}
  def remove_rule(index) do
    case Settings.get_selected_project() do
      {:ok, project_name} -> remove_rule(project_name, index)
      {:error, :project_not_set} -> {:error, :project_not_set}
    end
  end

  @doc """
  Removes the validation rule at the given 1-based index from the named
  project as part of maintaining its persisted validation rules.
  """
  @spec remove_rule(String.t(), integer()) ::
          {:ok, [rule()]} | {:error, :invalid_index | :project_not_found}
  def remove_rule(project_name, index) when is_binary(project_name) and is_integer(index) do
    case valid_index?(index) do
      false ->
        {:error, :invalid_index}

      true ->
        update_rules(project_name, fn rules ->
          remove_rule_at(rules, index)
        end)
    end
  end

  @doc """
  Clears all validation rules for the currently selected project, resetting the
  active project's validation rule set.
  """
  @spec clear() :: :ok | {:error, :project_not_found}
  def clear() do
    case Settings.get_selected_project() do
      {:ok, project_name} -> clear(project_name)
      {:error, :project_not_set} -> :ok
    end
  end

  @doc """
  Clears all validation rules for the named project by replacing its persisted
  validation rules with an empty list.
  """
  @spec clear(String.t()) :: :ok | {:error, :project_not_found}
  def clear(project_name) when is_binary(project_name) do
    case update_rules(project_name, fn _rules ->
           {:ok, []}
         end) do
      {:ok, _rules} -> :ok
      {:error, :project_not_found} -> {:error, :project_not_found}
    end
  end

  @spec get_rules(map() | nil) :: list()
  defp get_rules(nil), do: []

  defp get_rules(project_data) when is_map(project_data) do
    Map.get(project_data, "validation", [])
  end

  @spec normalize_rules(list()) :: [rule()]
  defp normalize_rules(rules) when is_list(rules) do
    rules
    |> Enum.map(&normalize_rule/1)
    |> Enum.reject(&is_nil/1)
  end

  @spec normalize_rule(term()) :: rule() | nil
  defp normalize_rule(%{"path_globs" => path_globs, "command" => command}) do
    with {:ok, normalized_globs} <- normalize_globs(path_globs),
         {:ok, normalized_command} <- normalize_command(command) do
      %{
        path_globs: normalized_globs,
        command: normalized_command
      }
    else
      _ -> nil
    end
  end

  defp normalize_rule(_other), do: nil

  # Builds a candidate rule from user input. Rejects the entire rule if any
  # individual glob is blank after trimming, since that indicates malformed
  # input rather than a glob to silently drop.
  @spec normalize_candidate_rule(term(), term()) :: rule() | nil
  defp normalize_candidate_rule(command, path_globs) when is_list(path_globs) do
    has_blank =
      Enum.any?(path_globs, fn
        g when is_binary(g) -> String.trim(g) == ""
        _ -> false
      end)

    if has_blank do
      nil
    else
      normalize_rule(%{"command" => command, "path_globs" => path_globs})
    end
  end

  defp normalize_candidate_rule(command, path_globs) do
    normalize_rule(%{"command" => command, "path_globs" => path_globs})
  end

  @spec dump_rule(rule()) :: map()
  defp dump_rule(%{path_globs: path_globs, command: command}) do
    %{
      "path_globs" => path_globs,
      "command" => command
    }
  end

  @spec put_rules(map(), [rule()]) :: map()
  defp put_rules(project_data, rules) when is_map(project_data) and is_list(rules) do
    Map.put(project_data, "validation", Enum.map(rules, &dump_rule/1))
  end

  @spec update_rules(String.t(), ([rule()] -> {:ok, [rule()]} | {:error, term()})) ::
          {:ok, [rule()]} | {:error, term()}
  defp update_rules(project_name, fun) when is_binary(project_name) and is_function(fun, 1) do
    settings = Settings.new()

    case Settings.get_project_data(settings, project_name) do
      nil ->
        {:error, :project_not_found}

      _project_data ->
        current_rules = list(project_name)

        case fun.(current_rules) do
          {:ok, updated_rules} ->
            settings =
              Settings.update(
                settings,
                "projects",
                fn projects ->
                  current_projects = normalize_projects(projects)
                  project_data = Map.fetch!(current_projects, project_name)
                  Map.put(current_projects, project_name, put_rules(project_data, updated_rules))
                end,
                %{}
              )

            updated_rules =
              settings
              |> Settings.get_project_data(project_name)
              |> get_rules()
              |> normalize_rules()

            {:ok, updated_rules}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @spec normalize_projects(term()) :: map()
  defp normalize_projects(projects) when is_map(projects), do: projects
  defp normalize_projects(_other), do: %{}

  @spec remove_rule_at([rule()], integer()) :: {:ok, [rule()]} | {:error, :invalid_index}
  defp remove_rule_at(rules, index) do
    zero_based_index = index - 1

    case zero_based_index < length(rules) do
      true -> {:ok, List.delete_at(rules, zero_based_index)}
      false -> {:error, :invalid_index}
    end
  end

  @spec valid_index?(term()) :: boolean()
  defp valid_index?(index) when is_integer(index) and index > 0, do: true
  defp valid_index?(_index), do: false

  @spec normalize_globs(term()) :: {:ok, [String.t()]} | :error
  defp normalize_globs(globs) when is_list(globs) do
    globs
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(&split_glob/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> :error
      normalized -> {:ok, normalized}
    end
  end

  defp normalize_globs(glob) when is_binary(glob) do
    normalize_globs([glob])
  end

  defp normalize_globs(_other), do: :error

  # Splits a glob string that may contain multiple space-separated patterns
  # into individual entries. Uses shell-style tokenization so quoted segments
  # with spaces are preserved as a single pattern.
  @spec split_glob(String.t()) :: [String.t()]
  defp split_glob(glob) do
    OptionParser.split(glob)
  end

  @spec normalize_command(term()) :: {:ok, String.t()} | :error
  defp normalize_command(command) when is_binary(command) do
    case String.trim(command) do
      "" -> :error
      normalized -> {:ok, normalized}
    end
  end

  defp normalize_command(_other), do: :error
end
