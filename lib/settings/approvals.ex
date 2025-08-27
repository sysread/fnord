defmodule Settings.Approvals do
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
    prefixes =
      settings
      |> get_approvals(:global, kind)
      |> Enum.concat([prefix])
      |> Enum.uniq()
      |> Enum.sort()

    approvals =
      settings
      |> get_approvals(:global)
      |> Map.put(kind, prefixes)

    settings
    |> Settings.set("approvals", approvals)
  end

  def approve(settings, :project, kind, prefix) do
    with {:ok, %{"name" => name} = project} <- Settings.get_project(settings) do
      prefixes =
        settings
        |> get_approvals(:project, kind)
        |> Enum.concat([prefix])
        |> Enum.uniq()
        |> Enum.sort()

      approvals =
        settings
        |> get_approvals(:project)
        |> Map.put(kind, prefixes)

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
    |> Enum.map(&prefix_to_regex(&1))
    |> Enum.any?(&Regex.match?(&1, subject))
  end

  def approved?(settings, :project, kind, subject) do
    settings
    |> get_approvals(:project, kind)
    |> Enum.map(&prefix_to_regex(&1))
    |> Enum.any?(&Regex.match?(&1, subject))
  end

  def prefix_to_pattern(prefix) do
    "^" <> Regex.escape(prefix) <> "(?=\\s|$)"
  end

  def prefix_to_regex(prefix) do
    prefix
    |> prefix_to_pattern()
    |> Regex.compile!()
  end
end
