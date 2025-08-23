defmodule Settings.Approvals do
  @type settings :: Settings.t()
  @type scope :: :project | :global
  @type kind :: binary
  @type pattern :: binary
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

  @spec get_approvals(settings, scope, kind) :: list(pattern)
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

  @spec approve(settings, scope, kind, pattern) :: settings
  def approve(settings, :global, kind, pattern) do
    patterns =
      settings
      |> get_approvals(:global, kind)
      |> Enum.concat([make_pattern(pattern)])
      |> Enum.uniq()
      |> Enum.sort()

    approvals =
      settings
      |> get_approvals(:global)
      |> Map.put(kind, patterns)

    settings
    |> Settings.set("approvals", approvals)
  end

  def approve(settings, :project, kind, pattern) do
    with {:ok, %{"name" => name} = project} <- Settings.get_project(settings) do
      patterns =
        settings
        |> get_approvals(:project, kind)
        |> Enum.concat([make_pattern(pattern)])
        |> Enum.uniq()
        |> Enum.sort()

      approvals =
        settings
        |> get_approvals(:project)
        |> Map.put(kind, patterns)

      project =
        project
        |> Map.put("approvals", approvals)

      settings
      |> Settings.set_project_data(name, project)
    else
      _ -> settings
    end
  end

  @spec approved?(settings, kind, subject) :: boolean
  def approved?(settings, kind, subject) do
    [:global, :project]
    |> Enum.any?(&approved?(settings, &1, kind, subject))
  end

  @spec approved?(settings, scope, kind, subject) :: boolean
  def approved?(settings, :global, kind, subject) do
    settings
    |> get_approvals(:global, kind)
    |> Enum.map(&Regex.compile!(&1))
    |> Enum.any?(&Regex.match?(&1, subject))
  end

  def approved?(settings, :project, kind, subject) do
    settings
    |> get_approvals(:project, kind)
    |> Enum.map(&Regex.compile!(&1))
    |> Enum.any?(&Regex.match?(&1, subject))
  end

  defp make_pattern(%Regex{} = pattern), do: Regex.source(pattern)
  defp make_pattern(pattern), do: pattern |> Regex.compile!() |> Regex.source()
end
