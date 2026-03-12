defmodule Skills do
  @moduledoc """
  Skills are TOML-defined agent presets that can be executed by the coordinator.

  This context module is the integration point that:
  - discovers skill definitions on disk,
  - applies precedence (user overrides project definitions by name),
  - applies enablement (via `Settings.Skills`), and
  - returns skill metadata suitable for dynamic tool specs and `fnord skills list`.

  Disk locations:
  - User skills:    `~/fnord/skills/*.toml`
  - Project skills: `~/.fnord/projects/<project>/skills/*.toml`

  Enablement:
  - Global settings key: `skills`
  - Project settings key: `projects.<project>.skills`

  Effective enablement is the union of the global and project lists.
  """

  @type definition :: %{
          skill: Skills.Skill.t(),
          source: Skills.Loader.skill_source(),
          path: String.t()
        }

  @type resolved_skill :: %{
          name: String.t(),
          effective: definition,
          definitions: [definition]
        }

  @type list_error :: Skills.Loader.load_error() | {:no_project_selected}

  @doc """
  List all resolved skills available for the current project context.

  Returned entries include all definition locations and the effective
  definition after applying precedence rules.

  This function does not filter to enabled skills.
  """
  @spec list_all() :: {:ok, [resolved_skill]} | {:error, list_error}
  def list_all() do
    with {:ok, user} <- Skills.Loader.load_dir(user_skills_dir(), :user),
         {:ok, project} <- load_project_skills() do
      {:ok, resolve_definitions(user, project)}
    end
  end

  @doc """
  List resolved skills that are enabled in the current project context.

  Enablement is controlled by `Settings.Skills`.
  """
  @spec list_enabled() :: {:ok, [resolved_skill]} | {:error, list_error}
  def list_enabled() do
    with {:ok, all} <- list_all() do
      enabled = Settings.Skills.effective_enabled()

      all
      |> Enum.filter(fn %{name: name} -> MapSet.member?(enabled, name) end)
      |> then(&{:ok, &1})
    end
  end

  @doc """
  Get a resolved skill by name.

  Returns `{:ok, resolved_skill}` if found, `{:error, :not_found}` otherwise.
  """
  @spec get(String.t()) :: {:ok, resolved_skill} | {:error, :not_found | list_error}
  def get(name) when is_binary(name) do
    with {:ok, all} <- list_all() do
      all
      |> Enum.find(fn %{name: n} -> n == name end)
      |> case do
        nil -> {:error, :not_found}
        found -> {:ok, found}
      end
    end
  end

  @doc """
  Get an enabled skill by name.
  Returns `{:ok, resolved_skill}` if the skill is enabled in the current project context, `{:error, :not_found | list_error}` otherwise.
  """
  @spec get_enabled(String.t()) :: {:ok, resolved_skill} | {:error, :not_found | list_error}
  def get_enabled(name) when is_binary(name) do
    with {:ok, enabled} <- list_enabled() do
      enabled
      |> Enum.find(fn %{name: n} -> n == name end)
      |> case do
        nil -> {:error, :not_found}
        found -> {:ok, found}
      end
    end
  end

  @doc """
  Returns the user skills directory path.

  This uses `Settings.get_user_home()` at runtime so tests can override HOME.
  """
  @spec user_skills_dir() :: String.t()
  def user_skills_dir() do
    Path.join([Settings.get_user_home(), "fnord", "skills"])
  end

  @doc """
  Returns the project skills directory for the currently selected project.
  """
  @spec project_skills_dir() :: {:ok, String.t()} | {:error, :no_project_selected}
  def project_skills_dir() do
    case Settings.get_selected_project() do
      {:ok, project} ->
        {:ok, Path.join([Settings.fnord_home(), "projects", project, "skills"])}

      _ ->
        {:error, :no_project_selected}
    end
  end

  defp load_project_skills() do
    case project_skills_dir() do
      {:ok, dir} -> Skills.Loader.load_dir(dir, :project)
      {:error, :no_project_selected} -> {:ok, []}
    end
  end

  defp resolve_definitions(user_loaded, project_loaded) do
    all = user_loaded ++ project_loaded

    all
    |> Enum.group_by(& &1.skill.name)
    |> Enum.map(fn {name, defs} ->
      %{name: name, effective: choose_effective(defs), definitions: defs}
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp choose_effective(defs) do
    # User definitions override project definitions.
    case Enum.find(defs, &(&1.source == :user)) do
      nil -> Enum.at(defs, 0)
      user_def -> user_def
    end
  end
end
