defmodule Settings.Approvals do
  alias Settings.Approvals.RegexMatcher

  @type settings :: Settings.t()
  @type scope :: :project | :global
  @type kind :: binary
  @type prefix :: binary
  @type subject :: binary

  @spec get_approvals(settings, scope) :: map
  def get_approvals(settings, :global) do
    case Settings.get(settings, "approvals", %{}) do
      nil -> %{}
      approvals when is_map(approvals) -> approvals
      _ -> %{}
    end
  end

  def get_approvals(settings, :project) do
    with {:ok, project} <- Settings.get_project(settings) do
      case Map.get(project, "approvals", %{}) do
        nil -> %{}
        approvals when is_map(approvals) -> approvals
        _ -> %{}
      end
    else
      _ -> %{}
    end
  end

  @spec get_approvals(settings, scope, kind) :: list(prefix)
  def get_approvals(settings, :global, kind) do
    settings
    |> get_approvals(:global)
    |> Map.get(kind, [])
    |> validate_approval_list(settings, :global, kind)
  end

  def get_approvals(settings, :project, kind) do
    settings
    |> get_approvals(:project)
    |> Map.get(kind, [])
    |> validate_approval_list(settings, :project, kind)
  end

  @spec approve(settings, scope, kind, prefix) :: settings
  def approve(settings, :global, kind, prefix) do
    Settings.update(settings, "approvals", fn
      approvals when is_map(approvals) ->
        existing = Map.get(approvals, kind, [])

        updated =
          existing
          |> Enum.concat([prefix])
          |> Enum.uniq()
          |> Enum.sort()

        Map.put(approvals, kind, updated)

      _other ->
        %{
          kind => [prefix]
        }
    end)
  end

  def approve(settings, :project, kind, prefix) do
    case Settings.get_project(settings) do
      {:ok, %{"name" => name}} ->
        # Use Settings.update to modify the nested project data safely
        Settings.update(settings, "projects", fn
          projects when is_map(projects) ->
            project = Map.get(projects, name, %{})
            approvals = Map.get(project, "approvals", %{})
            existing = Map.get(approvals, kind, [])

            updated_prefixes =
              existing
              |> Enum.concat([prefix])
              |> Enum.uniq()
              |> Enum.sort()

            updated_approvals = Map.put(approvals, kind, updated_prefixes)
            updated_project = Map.put(project, "approvals", updated_approvals)
            Map.put(projects, name, updated_project)

          _ ->
            %{
              name => %{"approvals" => %{kind => [prefix]}}
            }
        end)

      _ ->
        # Check if a project is selected but doesn't have data - create it
        case Settings.get_selected_project() do
          {:ok, project_name} ->
            Settings.update(settings, "projects", fn
              projects when is_map(projects) ->
                Map.put(projects, project_name, %{
                  "name" => project_name,
                  "approvals" => %{kind => [prefix]}
                })

              _ ->
                %{project_name => %{"name" => project_name, "approvals" => %{kind => [prefix]}}}
            end)

          _ ->
            settings
        end
    end
  end

  @spec approved?(settings, kind, subject) :: boolean
  def approved?(settings, kind, subject) do
    # Check both global and project scopes for any matching regex pattern
    [:global, :project]
    |> Enum.any?(&approved?(settings, &1, kind, subject))
  end

  def approved?(settings, :global, kind, subject) do
    get_approvals(settings, :global, kind)
    |> Enum.any?(&RegexMatcher.matches?(&1, subject))
  end

  def approved?(settings, :project, kind, subject) do
    get_approvals(settings, :project, kind)
    |> Enum.any?(&RegexMatcher.matches?(&1, subject))
  end

  @spec prefix_approved?(settings, kind, subject) :: boolean
  def prefix_approved?(settings, kind, subject) do
    # Check both global and project scopes for any matching prefix
    [:global, :project]
    |> Enum.any?(&prefix_approved?(settings, &1, kind, subject))
  end

  def prefix_approved?(settings, :global, kind, subject) do
    get_approvals(settings, :global, kind)
    |> Enum.any?(&String.starts_with?(subject, &1))
  end

  def prefix_approved?(settings, :project, kind, subject) do
    get_approvals(settings, :project, kind)
    |> Enum.any?(&String.starts_with?(subject, &1))
  end

  # ============================================================================
  # Data validation and corruption handling
  # ============================================================================

  # Validates and repairs corrupted approval lists.
  # When approval data is corrupted (e.g., not a list, contains non-strings, or is null),
  # this function warns the user and repairs the data by writing the corrected format
  # back to the settings file.
  @spec validate_approval_list(any, settings, scope, kind) :: list(prefix)
  defp validate_approval_list(data, settings, scope, kind) when is_list(data) do
    # Filter out non-string entries and warn if any were found
    valid_entries = Enum.filter(data, &is_binary/1)

    if length(valid_entries) != length(data) do
      invalid_count = length(data) - length(valid_entries)

      UI.warn(
        "Settings.Approvals",
        "Found #{invalid_count} invalid entries in #{scope} #{kind} approvals. Cleaning up..."
      )

      # Fix the corrupted data by re-approving only the valid entries
      repair_approval_list(settings, scope, kind, valid_entries)
    end

    valid_entries
  end

  defp validate_approval_list(data, settings, scope, kind) when is_nil(data) do
    UI.warn(
      "Settings.Approvals",
      "Found null #{scope} #{kind} approvals. Repairing..."
    )

    repair_approval_list(settings, scope, kind, [])
    []
  end

  defp validate_approval_list(data, settings, scope, kind) do
    UI.warn(
      "Settings.Approvals",
      "Found corrupted #{scope} #{kind} approvals (expected list, got #{inspect(data)}). Repairing..."
    )

    repair_approval_list(settings, scope, kind, [])
    []
  end

  # Repairs corrupted approval data by writing the correct format to settings.
  @spec repair_approval_list(settings, scope, kind, list(prefix)) :: :ok
  defp repair_approval_list(settings, :global, kind, valid_entries) do
    Settings.update(settings, "approvals", fn approvals ->
      approvals = if is_map(approvals), do: approvals, else: %{}
      Map.put(approvals, kind, valid_entries)
    end)

    :ok
  end

  defp repair_approval_list(settings, :project, kind, valid_entries) do
    with {:ok, %{"name" => name}} <- Settings.get_project(settings) do
      Settings.update(settings, "projects", fn projects ->
        projects = if is_map(projects), do: projects, else: %{}
        project = Map.get(projects, name, %{})
        approvals = Map.get(project, "approvals", %{})
        updated_approvals = Map.put(approvals, kind, valid_entries)
        updated_project = Map.put(project, "approvals", updated_approvals)
        Map.put(projects, name, updated_project)
      end)
    end

    :ok
  end
end
