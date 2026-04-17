defmodule Settings.ExternalConfigs do
  @moduledoc """
  Per-project toggles controlling whether fnord loads Cursor rules, Cursor
  skills, Claude Code skills, and Claude Code subagents from the project's
  source tree and the user's home directory.

  All toggles default to `false` - external configs are opt-in per project.
  Flags live under `["projects"][name]["external_configs"]` in `settings.json`
  and are keyed in colon-namespaced form for both CLI input and on-disk
  persistence:

      "external_configs": {
        "cursor:rules":  true,
        "cursor:skills": false,
        "claude:skills": true,
        "claude:agents": true
      }

  Internally, sources are Elixir atoms (`:cursor_rules` etc.); the colon
  form is a boundary representation only. See `source_to_string/1` and
  `source_from_string/1`.
  """

  @type source :: :cursor_rules | :cursor_skills | :claude_skills | :claude_agents

  @type flags :: %{
          cursor_rules: boolean(),
          cursor_skills: boolean(),
          claude_skills: boolean(),
          claude_agents: boolean()
        }

  @sources [:cursor_rules, :cursor_skills, :claude_skills, :claude_agents]
  @key "external_configs"

  # Atom <-> colon-namespaced string. The colon form is the *only*
  # user-visible spelling (CLI args, help text, settings.json keys, warn
  # messages). The atom form stays underscored so pattern matches and
  # module attribute names remain idiomatic.
  @source_strings %{
    cursor_rules: "cursor:rules",
    cursor_skills: "cursor:skills",
    claude_skills: "claude:skills",
    claude_agents: "claude:agents"
  }

  @strings_to_source Map.new(@source_strings, fn {k, v} -> {v, k} end)

  @doc "All supported external-config sources."
  @spec sources() :: [source()]
  def sources(), do: @sources

  @doc "Render a source atom as its user-facing colon-namespaced string."
  @spec source_to_string(source()) :: String.t()
  def source_to_string(source) when source in @sources do
    Map.fetch!(@source_strings, source)
  end

  @doc """
  Parse a colon-namespaced source string into its internal atom. Returns
  `{:ok, source}` on a known value, `{:error, {:invalid_source, raw}}`
  otherwise.
  """
  @spec source_from_string(String.t()) ::
          {:ok, source()} | {:error, {:invalid_source, String.t()}}
  def source_from_string(raw) when is_binary(raw) do
    case Map.fetch(@strings_to_source, raw) do
      {:ok, source} -> {:ok, source}
      :error -> {:error, {:invalid_source, raw}}
    end
  end

  @doc "The list of valid source strings, in declaration order."
  @spec source_strings() :: [String.t()]
  def source_strings() do
    Enum.map(@sources, &source_to_string/1)
  end

  @doc """
  Returns the flags for the currently selected project, or an all-false map
  when no project is selected.
  """
  @spec flags() :: flags()
  def flags() do
    case Settings.get_selected_project() do
      {:ok, project_name} -> flags(project_name)
      {:error, :project_not_set} -> defaults()
    end
  end

  @doc """
  Returns the flags for the named project, or an all-false map when the
  project has no `external_configs` settings.
  """
  @spec flags(String.t()) :: flags()
  def flags(project_name) when is_binary(project_name) do
    Settings.new()
    |> Settings.get_project_data(project_name)
    |> extract_flags()
  end

  @doc "Is the source enabled for the currently selected project?"
  @spec enabled?(source()) :: boolean()
  def enabled?(source) when source in @sources do
    Map.fetch!(flags(), source)
  end

  @doc "Is the source enabled for the named project?"
  @spec enabled?(String.t(), source()) :: boolean()
  def enabled?(project_name, source)
      when is_binary(project_name) and source in @sources do
    Map.fetch!(flags(project_name), source)
  end

  @doc """
  Enable or disable a source for the named project. Returns the new flags.
  """
  @spec set(String.t(), source(), boolean()) ::
          {:ok, flags()} | {:error, :project_not_found}
  def set(project_name, source, value)
      when is_binary(project_name) and source in @sources and is_boolean(value) do
    settings = Settings.new()

    case Settings.get_project_data(settings, project_name) do
      nil ->
        {:error, :project_not_found}

      _ ->
        current = flags(project_name)
        updated = Map.put(current, source, value)
        Settings.set_project_data(settings, project_name, %{@key => dump(updated)})
        {:ok, updated}
    end
  end

  defp defaults() do
    Map.new(@sources, &{&1, false})
  end

  defp extract_flags(nil), do: defaults()

  defp extract_flags(project_data) when is_map(project_data) do
    raw = Map.get(project_data, @key, %{})

    Enum.reduce(@sources, defaults(), fn source, acc ->
      case Map.get(raw, source_to_string(source)) do
        v when is_boolean(v) -> Map.put(acc, source, v)
        _ -> acc
      end
    end)
  end

  defp dump(flags) do
    Map.new(flags, fn {k, v} -> {source_to_string(k), v} end)
  end
end
