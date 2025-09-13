defmodule Settings.Approvals do
  alias Settings.Approvals.RegexMatcher

  @type settings :: Settings.t()
  @type scope :: :project | :global
  @type kind :: binary
  @type prefix :: binary
  @type subject :: binary

  @spec get_approvals(settings, scope) :: map
  def get_approvals(settings, :global) do
    settings
    |> Settings.get("approvals", %{})
  end

  def get_approvals(settings, :project) do
    with {:ok, project} <- Settings.get_project(settings) do
      project
      |> Map.get("approvals", %{})
    else
      _ -> %{}
    end
  end

  @spec get_approvals(settings, scope, kind) :: list(prefix)
  def get_approvals(settings, :global, kind) do
    settings
    |> get_approvals(:global)
    |> Map.get(kind, [])
  end

  def get_approvals(settings, :project, kind) do
    settings
    |> get_approvals(:project)
    |> Map.get(kind, [])
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
    with {:ok, %{"name" => name}} <- Settings.get_project(settings) do
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
    else
      _ -> settings
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
end
