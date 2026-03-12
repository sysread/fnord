defmodule Settings.Skills do
  @moduledoc """
  Manage skill enablement in settings.json.

  Schema:
    - Global:      ["skills"]                   :: [string]
    - Per-project: ["projects", pn, "skills"]  :: [string]

  ## Effective enablement (additive / union)

  The effective set of enabled skills is the union of the global list and the
  project list (when a project is selected). This matches the semantics used
  by `Settings.Frobs`.

  All mutations are performed via Settings APIs that provide cross-process locking
  and atomic writes.
  """

  @type scope :: :global | :project | {:project, String.t()}

  @doc """
  List enabled skill names for the given scope.

  - `:global` reads the top-level `skills` list.
  - `:project` reads the selected project's list (or returns `[]` if no project).
  - `{:project, name}` reads the named project's list.

  This function does not apply override semantics; it reads exactly the requested scope.
  """
  @spec list(scope) :: [String.t()]
  def list(:global) do
    Settings.get(Settings.new(), "skills", [])
    |> sanitize_list()
  end

  def list(:project) do
    case Settings.get_selected_project() do
      {:ok, pn} -> list({:project, pn})
      _ -> []
    end
  end

  def list({:project, pn}) when is_binary(pn) do
    settings = Settings.new()
    project = Settings.get_project_data(settings, pn) || %{}
    Map.get(project, "skills", []) |> sanitize_list()
  end

  @doc """
  Enable a skill in the given scope. Idempotent.
  """
  @spec enable(scope, String.t()) :: :ok
  def enable(scope, name) when is_binary(name) and byte_size(name) > 0 do
    names =
      list(scope)
      |> Kernel.++([name])
      |> sanitize_list()

    set_list(scope, names)
  end

  @doc """
  Disable a skill in the given scope. Idempotent.
  """
  @spec disable(scope, String.t()) :: :ok
  def disable(scope, name) when is_binary(name) do
    names =
      list(scope)
      |> Enum.reject(&(&1 == name))
      |> sanitize_list()

    set_list(scope, names)
  end

  @doc """
  Return the effective set of enabled skills for the current project context.

  Additive semantics: the effective set is the union of the global list and
  the project list (when a project is selected).

  The return is a `MapSet` for convenient membership checks.
  """
  @spec effective_enabled() :: MapSet.t(String.t())
  def effective_enabled() do
    global = list(:global)
    project = list(:project)

    (global ++ project)
    |> MapSet.new()
  end

  @doc """
  Is the given skill enabled in the current project context?
  """
  @spec enabled?(String.t()) :: boolean()
  def enabled?(name) when is_binary(name) do
    MapSet.member?(effective_enabled(), name)
  end

  # ----------------------------------------------------------------------------
  # Internals
  # ----------------------------------------------------------------------------

  defp sanitize_list(list) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp sanitize_list(_), do: []

  defp set_list(:global, names) when is_list(names) do
    Settings.update(Settings.new(), "skills", fn _ -> names end, [])
    :ok
  end

  defp set_list(:project, names) when is_list(names) do
    case Settings.get_selected_project() do
      {:ok, pn} -> set_list({:project, pn}, names)
      _ -> :ok
    end
  end

  defp set_list({:project, pn}, names) when is_list(names) and is_binary(pn) do
    settings = Settings.new()
    project = Settings.get_project_data(settings, pn) || %{}
    Settings.set_project_data(settings, pn, Map.put(project, "skills", names))
    :ok
  end
end
