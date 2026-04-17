defmodule ExternalConfigs.Loader do
  @moduledoc """
  Discovers and loads Cursor rules, Cursor skills, and Claude Code skills
  from the user's home directory and the current project's source root.

  Project-scoped entries override user/global entries of the same name
  (CSS-style layering).
  """

  require Logger

  # Single Services.Globals slot holding a map: %{{scope, project_name} => result}.
  # Cache lives for the invocation only; see clear_cache/0 for the test escape hatch.
  @cache_key :external_configs_loader_cache

  @type loaded :: %{
          cursor_rules: [ExternalConfigs.CursorRule.t()],
          cursor_skills: [ExternalConfigs.Skill.t()],
          claude_skills: [ExternalConfigs.Skill.t()],
          claude_agents: [ExternalConfigs.Agent.t()]
        }

  @doc """
  Load all enabled external configs for the given project, honoring the
  per-project `external_configs` settings toggles.
  """
  @spec load(Store.Project.t()) :: loaded
  def load(%Store.Project{} = project) do
    flags = Settings.ExternalConfigs.flags(project.name)

    %{
      cursor_rules: maybe_load(flags.cursor_rules, fn -> load_cursor_rules(project) end),
      cursor_skills: maybe_load(flags.cursor_skills, fn -> load_cursor_skills(project) end),
      claude_skills: maybe_load(flags.claude_skills, fn -> load_claude_skills(project) end),
      claude_agents: maybe_load(flags.claude_agents, fn -> load_claude_agents(project) end)
    }
  end

  @doc """
  Load only cursor rules (global + project) regardless of settings.
  Cached per session and per project. The hot path is the Injector,
  which reruns this on every file read/write while the rule set is
  stable for the life of the invocation.
  """
  @spec load_cursor_rules(Store.Project.t()) :: [ExternalConfigs.CursorRule.t()]
  def load_cursor_rules(%Store.Project{} = project) do
    cached(:cursor_rules, project, fn ->
      source_root = project.source_root
      global = discover_cursor_rules_dir(home_dir(".cursor/rules"), :global)

      project_rules =
        discover_cursor_rules_dir(project_dir(source_root, ".cursor/rules"), :project)

      legacy = discover_legacy_cursorrules(source_root)

      # Project overrides global; legacy is kept alongside (distinct name).
      merge_by_name(global, project_rules) ++ legacy
    end)
  end

  @doc """
  Load all cursor skills (global + project), project overriding global.
  Cached per session and per project.
  """
  @spec load_cursor_skills(Store.Project.t()) :: [ExternalConfigs.Skill.t()]
  def load_cursor_skills(%Store.Project{} = project) do
    cached(:cursor_skills, project, fn ->
      source_root = project.source_root
      global = discover_skills_dir(home_dir(".cursor/skills"), :cursor, :global)

      project_skills =
        discover_skills_dir(project_dir(source_root, ".cursor/skills"), :cursor, :project)

      merge_by_name(global, project_skills)
    end)
  end

  @doc """
  Load all Claude Code skills (global + project), project overriding global.
  Cached per session and per project.
  """
  @spec load_claude_skills(Store.Project.t()) :: [ExternalConfigs.Skill.t()]
  def load_claude_skills(%Store.Project{} = project) do
    cached(:claude_skills, project, fn ->
      source_root = project.source_root
      global = discover_skills_dir(home_dir(".claude/skills"), :claude, :global)

      project_skills =
        discover_skills_dir(project_dir(source_root, ".claude/skills"), :claude, :project)

      merge_by_name(global, project_skills)
    end)
  end

  @doc """
  Load all Claude Code subagents (global + project), project overriding
  global by name. Cached per session and per project.
  """
  @spec load_claude_agents(Store.Project.t()) :: [ExternalConfigs.Agent.t()]
  def load_claude_agents(%Store.Project{} = project) do
    cached(:claude_agents, project, fn ->
      source_root = project.source_root
      global = discover_agents_dir(home_dir(".claude/agents"), :global)
      project_agents = discover_agents_dir(project_dir(source_root, ".claude/agents"), :project)
      merge_by_name(global, project_agents)
    end)
  end

  @doc """
  Clears all external-configs loader caches. Call from tests that mutate
  the on-disk rules/skills mid-test; production code should never need
  this since the escript VM is short-lived.
  """
  @spec clear_cache() :: :ok
  def clear_cache() do
    Services.Globals.put_env(:fnord, @cache_key, %{})
    :ok
  end

  @doc """
  Cheap on-disk presence check, used by the coordinator's startup nudge
  to detect "feature is off, but the files are sitting right there."
  Skips parsing; just asks whether any candidate file exists under the
  global or project search paths for the given source.
  """
  @spec has_any_on_disk?(Store.Project.t(), Settings.ExternalConfigs.source()) :: boolean()
  def has_any_on_disk?(%Store.Project{source_root: source_root}, :cursor_rules) do
    any_mdc?(home_dir(".cursor/rules")) or
      any_mdc?(project_dir(source_root, ".cursor/rules")) or
      legacy_cursorrules_present?(source_root)
  end

  def has_any_on_disk?(%Store.Project{source_root: source_root}, :cursor_skills) do
    any_skill_md?(home_dir(".cursor/skills")) or
      any_skill_md?(project_dir(source_root, ".cursor/skills"))
  end

  def has_any_on_disk?(%Store.Project{source_root: source_root}, :claude_skills) do
    any_skill_md?(home_dir(".claude/skills")) or
      any_skill_md?(project_dir(source_root, ".claude/skills"))
  end

  def has_any_on_disk?(%Store.Project{source_root: source_root}, :claude_agents) do
    any_agent_md?(home_dir(".claude/agents")) or
      any_agent_md?(project_dir(source_root, ".claude/agents"))
  end

  defp any_mdc?(nil), do: false

  defp any_mdc?(dir) do
    File.dir?(dir) and
      dir
      |> Path.join("**/*.mdc")
      |> Path.wildcard()
      |> Enum.any?()
  end

  defp legacy_cursorrules_present?(nil), do: false
  defp legacy_cursorrules_present?(root), do: File.regular?(Path.join(root, ".cursorrules"))

  defp any_skill_md?(nil), do: false

  defp any_skill_md?(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.any?(fn entry ->
          File.dir?(entry) and File.regular?(Path.join(entry, "SKILL.md"))
        end)

      _ ->
        false
    end
  end

  defp any_agent_md?(nil), do: false

  defp any_agent_md?(dir) do
    File.dir?(dir) and
      dir
      |> Path.join("*.md")
      |> Path.wildcard()
      |> Enum.any?()
  end

  defp discover_agents_dir(nil, _source), do: []

  defp discover_agents_dir(dir, source) do
    case File.dir?(dir) do
      false ->
        []

      true ->
        dir
        |> Path.join("*.md")
        |> Path.wildcard()
        |> Enum.sort()
        |> Enum.map(&load_agent_file(&1, source))
        |> Enum.reject(&is_nil/1)
    end
  end

  defp load_agent_file(path, source) do
    case ExternalConfigs.Agent.from_file(path, source) do
      {:ok, agent} ->
        agent

      {:error, reason} ->
        Logger.warning("Failed to load Claude agent #{path}: #{inspect(reason)}")
        nil
    end
  end

  defp maybe_load(true, fun), do: fun.()
  defp maybe_load(_disabled, _fun), do: []

  # Memoize the result of `fun` under {scope, project_name, source_root,
  # home_dir} in Services.Globals. The scope lets three different loaders
  # share one map without colliding. source_root and home_dir are in the
  # key so tests that rebind HOME or rotate a project's source directory
  # don't see stale cache hits from a prior run inside the same VM.
  defp cached(scope, %Store.Project{name: project_name, source_root: source_root}, fun) do
    cache = Services.Globals.get_env(:fnord, @cache_key, %{})
    key = {scope, project_name, source_root, Settings.get_user_home()}

    case Map.fetch(cache, key) do
      {:ok, cached_result} ->
        cached_result

      :error ->
        result = fun.()
        Services.Globals.put_env(:fnord, @cache_key, Map.put(cache, key, result))
        result
    end
  end

  defp project_dir(nil, _sub), do: nil
  defp project_dir(root, sub), do: Path.join(root, sub)

  # Routes through Settings.get_user_home/0 rather than Path.expand("~").
  # Path.expand resolves via init:get_argument(home), frozen at VM init
  # and unaware of runtime $HOME overrides. The test harness relies on
  # the runtime override.
  defp home_dir(sub), do: Path.join(Settings.get_user_home(), sub)

  defp discover_cursor_rules_dir(nil, _source), do: []

  defp discover_cursor_rules_dir(dir, source) do
    case File.dir?(dir) do
      false ->
        []

      true ->
        dir
        |> Path.join("**/*.mdc")
        |> Path.wildcard()
        |> Enum.sort()
        |> Enum.map(&load_rule_file(&1, source))
        |> Enum.reject(&is_nil/1)
    end
  end

  defp load_rule_file(path, source) do
    case ExternalConfigs.CursorRule.from_file(path, source) do
      {:ok, rule} ->
        rule

      {:error, reason} ->
        Logger.warning("Failed to load cursor rule #{path}: #{inspect(reason)}")
        nil
    end
  end

  defp discover_legacy_cursorrules(nil), do: []

  defp discover_legacy_cursorrules(source_root) do
    path = Path.join(source_root, ".cursorrules")

    case File.regular?(path) do
      true ->
        case ExternalConfigs.CursorRule.from_legacy_file(path) do
          {:ok, rule} ->
            [rule]

          {:error, reason} ->
            Logger.warning("Failed to load legacy .cursorrules #{path}: #{inspect(reason)}")
            []
        end

      false ->
        []
    end
  end

  defp discover_skills_dir(nil, _flavor, _source), do: []

  defp discover_skills_dir(dir, flavor, source) do
    case File.dir?(dir) do
      false ->
        []

      true ->
        dir
        |> File.ls!()
        |> Enum.sort()
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.map(&load_skill_dir(&1, flavor, source))
        |> Enum.reject(&is_nil/1)
    end
  end

  defp load_skill_dir(dir, flavor, source) do
    case ExternalConfigs.Skill.from_dir(dir, flavor, source) do
      {:ok, skill} ->
        skill

      {:error, :enoent} ->
        # No SKILL.md in this directory; ignore silently.
        nil

      {:error, reason} ->
        Logger.warning("Failed to load #{flavor} skill from #{dir}: #{inspect(reason)}")
        nil
    end
  end

  # Project entries override global entries with the same name. The list is
  # returned sorted by name for stable output.
  defp merge_by_name(global, project) do
    by_name = Map.new(global, &{&1.name, &1})

    project
    |> Enum.reduce(by_name, fn item, acc -> Map.put(acc, item.name, item) end)
    |> Map.values()
    |> Enum.sort_by(& &1.name)
  end
end
