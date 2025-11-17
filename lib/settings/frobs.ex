defmodule Settings.Frobs do
  @moduledoc """
  Manage frob enablement in settings.json using approvals-style arrays.

  Schema:
    - Global:    ["frobs"]            :: [string]
    - Per-project: ["projects", pn, "frobs"] :: [string]


  Effective enablement is the union of global and current project's frobs.
  All mutations are performed via Settings APIs that provide cross-process locking
  and atomic writes.
  """

  @type scope :: :global | :project | {:project, String.t()}

  @doc """
  List enabled frobs for the given scope.
  """
  @spec list(scope) :: [String.t()]
  def list(:global) do
    Settings.get(Settings.new(), "frobs", [])
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
    Map.get(project, "frobs", []) |> sanitize_list()
  end

  @doc """
  Enable a frob in the given scope. Idempotent.
  """
  @spec enable(scope, String.t()) :: :ok
  def enable(scope, name) when is_binary(name) and byte_size(name) > 0 do
    names =
      list(scope)
      |> List.wrap()
      |> Kernel.++([name])
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.sort()

    set_list(scope, names)
  end

  @doc """
  Disable a frob in the given scope. Idempotent.
  """
  @spec disable(scope, String.t()) :: :ok
  def disable(scope, name) when is_binary(name) do
    names =
      list(scope)
      |> Enum.reject(&(&1 == name))

    set_list(scope, names)
  end

  @doc """
  Return the effective set of enabled frobs for the current project context
  (union of global and project lists).
  """
  @spec effective_enabled() :: MapSet.t(String.t())
  def effective_enabled() do
    global = list(:global)

    project =
      case Settings.get_selected_project() do
        {:ok, _} -> list(:project)
        _ -> []
      end

    MapSet.new(global ++ project)
  end

  @doc """
  Is the given frob enabled (effective union)?
  """
  @spec enabled?(String.t()) :: boolean()
  def enabled?(name) when is_binary(name) do
    MapSet.member?(effective_enabled(), name)
  end

  @doc """
  Prune missing frobs from settings based on the given list of present frob names.

  This removes any frob names that are not found in `present_names` from:
  - the global `frobs` array, and
  - the currently selected project's `frobs` array (if a project is selected)

  Returns the list of names that were retained.
  """
  @spec prune_missing!([String.t()]) :: [String.t()]
  def prune_missing!(present_names) when is_list(present_names) do
    set =
      present_names
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    # Prune global list atomically
    Settings.update(
      Settings.new(),
      "frobs",
      fn current ->
        current_list = if is_list(current), do: current, else: []

        current_list
        |> Enum.filter(&MapSet.member?(set, &1))
        |> Enum.uniq()
        |> Enum.sort()
      end,
      []
    )

    # Prune currently selected project's list, if any
    case Settings.get_selected_project() do
      {:ok, pn} ->
        settings = Settings.new()
        project = Settings.get_project_data(settings, pn) || %{}

        pruned =
          project
          |> Map.get("frobs", [])
          |> Enum.filter(&MapSet.member?(set, &1))
          |> Enum.uniq()
          |> Enum.sort()

        _ = Settings.set_project_data(settings, pn, Map.put(project, "frobs", pruned))
        :ok

      _ ->
        :ok
    end

    # Return the list of names that were not removed (i.e., kept)
    present_names
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.sort()
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
    Settings.update(Settings.new(), "frobs", fn _ -> names end, [])
    :ok
  end

  defp set_list(:project, names) when is_list(names) do
    case Settings.get_selected_project() do
      {:ok, pn} ->
        settings = Settings.new()
        project = Settings.get_project_data(settings, pn) || %{}
        Settings.set_project_data(settings, pn, Map.put(project, "frobs", names))
        :ok

      _ ->
        :ok
    end
  end

  defp set_list({:project, pn}, names) when is_list(names) and is_binary(pn) do
    settings = Settings.new()
    project = Settings.get_project_data(settings, pn) || %{}
    Settings.set_project_data(settings, pn, Map.put(project, "frobs", names))
    :ok
  end
end
