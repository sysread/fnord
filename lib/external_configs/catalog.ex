defmodule ExternalConfigs.Catalog do
  @moduledoc """
  Builds the external-configs section of the coordinator's system prompt.

  Emits a single combined "available skills" message that groups:

    * fnord's own enabled skills (via `Skills.list_enabled/0`)
    * project-enabled Cursor skills
    * project-enabled Claude Code skills

  Also emits a compact "available Cursor rules" listing covering modes
  other than `:always` (agent-requested and auto-attached rules), plus one
  full-body message per `:always` rule.

  All messages are system-role messages; they are filtered out when the
  conversation is persisted to disk (see `Services.Conversation`).
  """

  alias ExternalConfigs.Agent
  alias ExternalConfigs.CursorRule
  alias ExternalConfigs.Skill

  # Claude-agent tool names that require fnord's edit mode to be
  # meaningfully actionable. An agent whose instructions assume Write or
  # Edit access is useless in research mode, so we hide it from the
  # catalog until --edit is on.
  @edit_requiring_tools ["Write", "Edit"]

  @desc_truncate 240

  @type skills_section :: {String.t(), [%{name: String.t(), description: String.t() | nil}]}

  @doc """
  Build all prompt messages for the current project's external configs.
  Returns an ordered list of system-message strings, each intended to be
  appended to the conversation as its own system message.

  Safe when no project is selected, when the project has source_root = nil,
  or when no toggles are enabled; in those cases it returns `[]`.
  """
  @spec build_messages() :: [String.t()]
  def build_messages() do
    with {:ok, project} <- Store.get_project() do
      build_messages(project)
    else
      _ -> []
    end
  end

  @doc """
  Convenience wrapper: `build_messages/0` with each string already wrapped
  as a system-role message. Intended for sub-agents that build their own
  `messages` list and need to inherit the external-configs catalog so
  their LLM call knows about the parent session's enabled sources.

  Sub-agents get the same skills catalog, cursor rules catalog listing,
  and always-apply rule bodies the coordinator got at its own bootstrap.
  They do NOT inherit mid-stream auto-attach injections from the parent
  conversation; those live in `Services.Conversation` which sub-agents
  don't read from. The rule bodies remain reachable via the paths listed
  in the catalog.
  """
  @spec system_messages() :: [map()]
  def system_messages() do
    build_messages() |> Enum.map(&AI.Util.system_msg/1)
  end

  @doc """
  Build all prompt messages for the given project. Same shape as
  `build_messages/0`, but skips the `Store.get_project/0` lookup. Intended
  for callers that already have the project in hand (tests, the injector's
  matching path).
  """
  @spec build_messages(Store.Project.t()) :: [String.t()]
  def build_messages(%Store.Project{} = project) do
    loaded = ExternalConfigs.Loader.load(project)
    fnord_skills = fnord_skill_entries()
    {visible_agents, hidden_agent_count} = partition_agents(loaded.claude_agents)

    ([
       skills_catalog_message(
         fnord_skills,
         loaded.cursor_skills,
         loaded.claude_skills,
         visible_agents,
         hidden_agent_count
       ),
       cursor_rules_catalog_message(loaded.cursor_rules)
     ] ++ cursor_rule_always_messages(loaded.cursor_rules))
    |> Enum.reject(&is_nil/1)
  end

  # ----------------------------------------------------------------------------
  # Skills catalog
  # ----------------------------------------------------------------------------
  # All four item lists empty: emit the hidden-agents-only note when there
  # are edit-requiring agents we filtered out in research mode; otherwise
  # suppress the whole section. Without the hidden_agents check here,
  # maybe_hidden_agents_only_note/1 (written for exactly this scenario)
  # was unreachable - the catch-all skills_catalog_message/5 clause
  # swallowed the case before the case-statement inside the body could
  # dispatch to it.
  defp skills_catalog_message([], [], [], [], 0), do: nil
  defp skills_catalog_message([], [], [], [], hidden), do: maybe_hidden_agents_only_note(hidden)

  defp skills_catalog_message(fnord, cursor, claude, agents, hidden_agents) do
    sections =
      [
        {"You have these skills available (invoke via `run_skill`):", fnord},
        {"You also have these Cursor skills available. Their bodies live at each entry's path; read the SKILL.md with `file_contents_tool` when a task matches the description, and follow its guidance.",
         cursor_entries(cursor)},
        {"You also have these Claude Code skills available. Same mechanism: read the SKILL.md with `file_contents_tool` when a task matches the description, and follow its guidance.",
         claude_entries(claude)},
        {"You also have these Claude Code subagents available. They're role definitions (system prompt + allowed tools) rather than procedures; read the file with `file_contents_tool` when a task matches the description and internalize the role for that turn.",
         agent_entries(agents)}
      ]
      |> Enum.reject(fn {_heading, items} -> items == [] end)

    case sections do
      [] ->
        maybe_hidden_agents_only_note(hidden_agents)

      _ ->
        rendered =
          sections
          |> Enum.map(fn {heading, items} ->
            heading <> "\n" <> render_skill_list(items)
          end)
          |> Enum.join("\n\n")

        rendered <> hidden_agents_note(hidden_agents)
    end
  end

  # Hide agents whose tool list implies edit capability when edit mode is
  # off; following their guidance requires tools the coordinator doesn't
  # have available in research mode.
  defp partition_agents(agents) do
    edit_mode? = Settings.get_edit_mode()

    Enum.reduce(agents, {[], 0}, fn %Agent{} = a, {visible, hidden} ->
      if edit_mode? or not agent_requires_edit?(a) do
        {[a | visible], hidden}
      else
        {visible, hidden + 1}
      end
    end)
    |> then(fn {visible, hidden} -> {Enum.reverse(visible), hidden} end)
  end

  defp agent_requires_edit?(%Agent{tools: tools}) do
    Enum.any?(tools, &(&1 in @edit_requiring_tools))
  end

  defp hidden_agents_note(0), do: ""

  defp hidden_agents_note(n) do
    "\n\n(#{n} additional Claude Code agent#{plural(n)} require edit mode and " <>
      "#{pronoun(n)} not listed; rerun with --edit to include #{object(n)}.)"
  end

  defp maybe_hidden_agents_only_note(0), do: nil
  defp maybe_hidden_agents_only_note(n), do: String.trim_leading(hidden_agents_note(n))

  defp plural(1), do: ""
  defp plural(_), do: "s"
  defp pronoun(1), do: "is"
  defp pronoun(_), do: "are"
  defp object(1), do: "it"
  defp object(_), do: "them"

  defp fnord_skill_entries() do
    case Skills.list_enabled() do
      {:ok, resolved} ->
        Enum.map(resolved, fn %{effective: %{skill: s}} ->
          %{name: s.name, description: s.description, path: nil}
        end)

      _ ->
        []
    end
  end

  defp cursor_entries(skills), do: skill_entries(skills)
  defp claude_entries(skills), do: skill_entries(skills)

  defp agent_entries(agents) do
    Enum.map(agents, fn %Agent{} = a ->
      %{name: a.name, description: a.description, path: a.path}
    end)
  end

  defp skill_entries(skills) do
    Enum.map(skills, fn %Skill{} = s ->
      %{name: s.name, description: combine_skill_description(s), path: s.path}
    end)
  end

  defp combine_skill_description(%Skill{description: d, when_to_use: nil}), do: d

  defp combine_skill_description(%Skill{description: nil, when_to_use: w}), do: w

  defp combine_skill_description(%Skill{description: d, when_to_use: w}),
    do: d <> " - " <> w

  defp render_skill_list(items) do
    items
    |> Enum.map(fn
      %{name: name, description: desc, path: nil} ->
        "- #{name}: #{truncate(desc)}"

      %{name: name, description: desc, path: path} ->
        "- #{name} (#{path}): #{truncate(desc)}"
    end)
    |> Enum.join("\n")
  end

  # ----------------------------------------------------------------------------
  # Cursor rules
  # ----------------------------------------------------------------------------
  defp cursor_rules_catalog_message([]), do: nil

  defp cursor_rules_catalog_message(rules) do
    listed =
      rules
      |> Enum.reject(&(&1.mode == :always))
      |> Enum.sort_by(& &1.name)

    case listed do
      [] ->
        nil

      _ ->
        debug_log_catalog(listed)

        body =
          listed
          |> Enum.map(&render_rule_summary/1)
          |> Enum.join("\n")

        """
        This project is configured to use Cursor rules. The following rules are available (bodies will be injected on demand when they are triggered or when you request them):

        #{body}
        """
        |> String.trim_trailing()
    end
  end

  defp render_rule_summary(%CursorRule{} = r) do
    mode =
      case r.mode do
        :auto_attached -> "auto-attached"
        :agent_requested -> "agent-requested"
        :manual -> "manual"
        :always -> "always"
      end

    globs =
      case r.globs do
        [] -> ""
        gs -> " (globs: #{Enum.join(gs, ", ")})"
      end

    desc =
      case r.description do
        nil -> "(no description)"
        d -> truncate(d)
      end

    "- #{r.name} [#{mode}]#{globs}: #{desc}"
  end

  defp cursor_rule_always_messages(rules) do
    always_rules =
      rules
      |> Enum.filter(&(&1.mode == :always))
      |> Enum.sort_by(& &1.name)

    Enum.each(always_rules, &debug_log_always/1)

    Enum.map(always_rules, &render_rule_body/1)
  end

  defp render_rule_body(%CursorRule{} = r) do
    """
    Cursor rule `#{r.name}` (always-applied, source: #{r.source}, path: #{r.path}):

    #{r.body}
    """
    |> String.trim_trailing()
  end

  # ----------------------------------------------------------------------------
  # Auto-attached rule injection (called from file read/write tools)
  # ----------------------------------------------------------------------------
  @doc """
  Render the system-message body that is injected when an auto-attached rule
  matches a file the model has just read or written. Includes the triggering
  file's path so the model can cite it back to the user.
  """
  @spec render_auto_attached_rule(CursorRule.t(), String.t()) :: String.t()
  def render_auto_attached_rule(%CursorRule{} = rule, file_path) do
    """
    Cursor rule `#{rule.name}` was auto-attached because it matches `#{file_path}` (source: #{rule.source}, path: #{rule.path}):

    #{rule.body}
    """
    |> String.trim_trailing()
  end

  defp truncate(nil), do: "(no description)"

  defp truncate(text) when is_binary(text) do
    text = text |> String.trim() |> String.replace(~r/\s+/, " ")

    if String.length(text) > @desc_truncate do
      String.slice(text, 0, @desc_truncate - 3) <> "..."
    else
      text
    end
  end

  # ----------------------------------------------------------------------------
  # Debug logging (gated by FNORD_DEBUG_CURSOR_RULES)
  # ----------------------------------------------------------------------------
  defp debug_log_always(%CursorRule{} = r) do
    if Util.Env.cursor_rules_debug_enabled?() do
      UI.debug(
        "cursor_rules",
        format_kv("always-apply rule injected at bootstrap",
          name: r.name,
          source: r.source,
          path: r.path
        )
      )
    end
  end

  defp debug_log_catalog(rules) do
    if Util.Env.cursor_rules_debug_enabled?() do
      entries = Enum.map(rules, fn r -> "#{r.name} (#{r.mode})" end)

      UI.debug(
        "cursor_rules",
        format_kv("catalog listing non-always rules",
          count: length(rules),
          rules: entries
        )
      )
    end
  end

  # Render a keyword list as a multi-line markdown list. List-valued entries
  # nest a second level of bullets for readability.
  defp format_kv(header, pairs) do
    lines =
      Enum.map(pairs, fn
        {k, values} when is_list(values) ->
          nested = Enum.map_join(values, "\n", fn v -> "  - #{v}" end)
          "- #{k}:\n#{nested}"

        {k, v} ->
          "- #{k}: #{v}"
      end)

    Enum.join([header | lines], "\n")
  end
end
