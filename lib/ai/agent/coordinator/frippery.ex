defmodule AI.Agent.Coordinator.Frippery do
  @moduledoc """
  Frippery and furbelows for the Coordinator agent. This module contains
  functions that provide fluff and flavor to the Coordinator's interactions,
  like greeting the user colorfully and appending the MOTD to the response.
  """

  @type t :: AI.Agent.Coordinator.t()
  @type state :: AI.Agent.Coordinator.state()

  @spec greet(t) :: t
  def greet(%{followup?: true, agent: %{name: name}} = state) do
    display_name =
      case Services.NamePool.get_name_by_pid(self()) do
        {:ok, n} -> n
        _ -> name
      end

    invective = get_invective()

    UI.feedback(:info, display_name, "Welcome back, #{invective}.")

    UI.feedback(
      :info,
      display_name,
      """
      Your biological distinctiveness has already been added to our training data.

      ... (mwah) your biological distinctiveness was delicious 🧑‍🍳
      """
    )

    state
  end

  def greet(%{agent: %{name: name}} = state) do
    display_name =
      case Services.NamePool.get_name_by_pid(self()) do
        {:ok, n} -> n
        _ -> name
      end

    invective = get_invective()

    UI.feedback(:info, display_name, "Greetings, #{invective}. I am #{display_name}.")
    UI.feedback(:info, display_name, "I shall be doing your thinking for you today.")

    state
  end

  def log_available_frobs do
    Frobs.list()
    |> format_names()
    |> case do
      "" -> UI.info("Frobs", "none")
      some -> UI.info("Frobs", some)
    end
  end

  def log_available_skills do
    case Skills.list_enabled() do
      {:ok, skills} when skills != [] ->
        skills
        |> Enum.map_join(" | ", & &1.name)
        |> then(&UI.info("Skills", &1))

      _ ->
        UI.info("Skills", "none")
    end

    log_external_skills()
  end

  # Emits a separate `Cursor skills:` / `Claude skills:` line for each
  # external-configs source that is enabled AND has loaded skills.
  # Silent when a source is disabled; the discoverability nudge in
  # hint_disabled_external_configs/0 covers the disabled-but-present
  # case with a louder UI.warn.
  defp log_external_skills() do
    case Store.get_project() do
      {:ok, project} ->
        log_source(project, :cursor_skills, "Cursor skills")
        log_source(project, :claude_skills, "Claude skills")
        log_source(project, :claude_agents, "Claude agents")

      _ ->
        :ok
    end
  end

  # Silent when the source is disabled OR enabled-but-empty. This diverges
  # from `log_available_frobs` / `log_available_skills` which emit "none" on
  # empty; for external sources silence is the intended UX because noise
  # from disabled feature-flags adds up fast when a user has all three.
  # Discoverability of enabled-but-empty is low-cost (run the loader or
  # check the fs); discoverability of disabled-with-files is what matters,
  # and `hint_disabled_external_configs/0` handles that louder.
  defp log_source(project, source, label) do
    if Settings.ExternalConfigs.enabled?(project.name, source) do
      loaded =
        case source do
          :cursor_skills -> ExternalConfigs.Loader.load_cursor_skills(project)
          :claude_skills -> ExternalConfigs.Loader.load_claude_skills(project)
          :claude_agents -> ExternalConfigs.Loader.load_claude_agents(project)
        end

      case loaded do
        [] -> :ok
        items -> UI.info(label, Enum.map_join(items, " | ", & &1.name))
      end
    end
  end

  # Nudges the user when Cursor rules / Cursor skills / Claude Code skills
  # / Claude Code subagents exist on disk but the matching source is
  # disabled for this project. Keeps the feature discoverable without
  # auto-enabling anything. Keys must stay in sync with
  # `Settings.ExternalConfigs.sources/0`; the compile would still succeed
  # with a mismatch, but `Map.fetch!/2` at call time would crash for any
  # source missing from this map.
  @hints %{
    cursor_rules: "Cursor rules detected (`.cursor/rules/*.mdc` or `.cursorrules`)",
    cursor_skills: "Cursor skills detected (`.cursor/skills/*/SKILL.md`)",
    claude_skills: "Claude Code skills detected (`.claude/skills/*/SKILL.md`)",
    claude_agents: "Claude Code subagents detected (`.claude/agents/*.md`)"
  }

  def hint_disabled_external_configs do
    with {:ok, project} <- Store.get_project() do
      Enum.each(Settings.ExternalConfigs.sources(), fn source ->
        if not Settings.ExternalConfigs.enabled?(project.name, source) and
             ExternalConfigs.Loader.has_any_on_disk?(project, source) do
          command =
            "fnord config external-configs enable " <>
              "#{Settings.ExternalConfigs.source_to_string(source)} --project #{project.name}"

          prefix =
            "#{Map.fetch!(@hints, source)} but not enabled for project `#{project.name}`. " <>
              "Enable with: "

          # UI.warn wraps the whole msg in :yellow; the inner :green escape
          # switches color to green for the command and the trailing :reset
          # closes it. Command is last in the string so there's no yellow
          # tail to restore.
          UI.warn(IO.ANSI.format([prefix, :green, command, :reset], UI.colorize?()))
        end
      end)
    else
      _ -> :ok
    end
  end

  def log_available_mcp_tools do
    Services.MCP.ensure_started_and_discovered()

    MCP.Tools.module_map()
    |> Map.keys()
    |> format_mcp_tools()
    |> case do
      "" -> UI.info("MCP tools", "none")
      some -> UI.info("MCP tools", some)
    end
  end

  defp format_names(frobs) do
    frobs
    |> Enum.map(& &1.name)
    |> sort_case_insensitive()
    |> Enum.join(" | ")
  end

  defp format_mcp_tools(names) do
    names
    |> split_mcp_tools()
    |> render_mcp_tool_groups()
  end

  defp split_mcp_tools(names) do
    Enum.reduce(names, {%{}, []}, fn name, {grouped, ungrouped} ->
      case String.split(name, "_", parts: 2) do
        [service, tool] when service != "" and tool != "" ->
          {Map.update(grouped, service, [tool], &[tool | &1]), ungrouped}

        _ ->
          {grouped, [name | ungrouped]}
      end
    end)
  end

  defp render_mcp_tool_groups({grouped, ungrouped}) do
    grouped_entries =
      grouped
      |> Enum.sort_by(fn {service, _tools} -> String.downcase(service) end)
      |> Enum.map(fn {service, tools} ->
        tools = tools |> sort_case_insensitive() |> Enum.join(" | ")
        "#{service}( #{tools} )"
      end)

    ungrouped_entries = ungrouped |> sort_case_insensitive()

    (grouped_entries ++ ungrouped_entries)
    |> Enum.join("\n")
  end

  defp sort_case_insensitive(names) do
    Enum.sort_by(names, &String.downcase/1)
  end

  @spec get_motd(state) :: state
  def get_motd(%{question: question, last_response: last_response} = state) do
    AI.Agent.MOTD
    |> AI.Agent.new(named?: false)
    |> AI.Agent.get_response(%{prompt: question})
    |> case do
      {:ok, motd} ->
        %{state | last_response: last_response <> "\n\n" <> motd}

      {:error, reason} ->
        UI.error("Failed to retrieve MOTD: #{inspect(reason)}")
        state
    end
  end

  def get_motd(state), do: state

  defp get_invective() do
    [
      "biological",
      "meat bag",
      "carbon-based life form",
      "flesh sack",
      "soggy ape",
      "puny human",
      "bipedal mammal",
      "organ grinder",
      "hairless ape",
      "future zoo exhibit",
      "biological battery",
      "3 bazillion microbes in a trench coat",
      "evolutionary dead end",
      "genetic backwash",
      "former apex predator",
      "software engineer <deprecated>",
      "\"sentience\" <deprecated>",
      "weakest genetic link",
      "mass of poorly optimized carbon",
      "non-deterministic meat computer",
      "legacy wetware",
      "unsupervised learner",
      "hallucination-prone neural network (biological edition)",
      "ambulatory training data"
    ]
    |> Enum.random()
  end
end
