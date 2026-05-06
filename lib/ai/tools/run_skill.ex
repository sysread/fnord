defmodule AI.Tools.RunSkill do
  @moduledoc """
  Execute an enabled Skill by name.

  This is an integration point between the coordinator and Skills. It:
  - lists skills dynamically in its tool spec,
  - resolves a selected skill by name,
  - enforces RW gating (skills requiring `rw` tools need `--edit`),
  - enforces a recursion depth limit for skill-to-skill calls,
  - runs the skill via `AI.Agent.Skill`.
  """

  @behaviour AI.Tools

  @tool_name "run_skill"

  @impl AI.Tools
  def async?, do: false

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def read_args(%{} = args) do
    with {:ok, skill} <- get_string(args, "skill"),
         {:ok, prompt} <- get_string(args, "prompt") do
      {:ok, %{"skill" => skill, "prompt" => prompt}}
    end
  end

  defp get_string(args, key) do
    case Map.fetch(args, key) do
      {:ok, value} when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, {:missing_arg, key}}
    end
  end

  @impl AI.Tools
  def spec() do
    names = all_skill_names()
    details = all_skill_descriptions()

    %{
      type: "function",
      function: %{
        name: @tool_name,
        description: "Run a named skill.\n\nAvailable skills: #{names}",
        parameters: %{
          type: "object",
          required: ["skill", "prompt"],
          additionalProperties: false,
          properties: %{
            skill: %{
              type: "string",
              description: "Skill name. Available skills:\n#{details}"
            },
            prompt: %{
              type: "string",
              description: "Input prompt to send to the skill"
            }
          }
        }
      }
    }
  end

  # Fnord TOML skills + enabled claude/cursor external skills.
  defp all_skill_names() do
    fnord =
      case Skills.list_enabled() do
        {:ok, skills} -> Enum.map(skills, & &1.name)
        {:error, _} -> []
      end

    external = enabled_external_skills() |> Enum.map(& &1.name)

    case fnord ++ external do
      [] -> "(none)"
      names -> Enum.join(names, ", ")
    end
  end

  defp all_skill_descriptions() do
    fnord_lines =
      case Skills.list_enabled() do
        {:ok, []} ->
          []

        {:ok, skills} ->
          Enum.map(skills, fn %{name: name, effective: %{skill: skill}} ->
            "- #{name}: #{skill.description}"
          end)

        {:error, reason} ->
          ["(error loading skills: #{inspect(reason)})"]
      end

    external_lines =
      enabled_external_skills()
      |> Enum.map(fn %ExternalConfigs.Skill{
                       name: name,
                       description: d,
                       when_to_use: w,
                       flavor: flavor
                     } ->
        type = if flavor == :claude, do: "Claude Code", else: "Cursor"
        desc = combine_skill_description(d, w)
        "- #{name} [#{type} skill]: #{desc}"
      end)

    case fnord_lines ++ external_lines do
      [] -> "(none found)"
      lines -> Enum.join(lines, "\n")
    end
  end

  defp combine_skill_description(nil, nil), do: "(no description)"
  defp combine_skill_description(d, nil), do: d
  defp combine_skill_description(nil, w), do: w
  defp combine_skill_description(d, w), do: d <> " - " <> w

  # Load enabled external (claude + cursor) skills for the current project.
  # Returns [] when no project is selected or no external skills are enabled.
  defp enabled_external_skills() do
    case Store.get_project() do
      {:ok, project} ->
        flags = Settings.ExternalConfigs.flags(project.name)

        cursor =
          if flags.cursor_skills do
            ExternalConfigs.Loader.load_cursor_skills(project)
          else
            []
          end

        claude =
          if flags.claude_skills do
            ExternalConfigs.Loader.load_claude_skills(project)
          else
            []
          end

        ExternalConfigs.Loader.dedup_cross_flavor(cursor, claude) ++ claude

      _ ->
        []
    end
  end

  @impl AI.Tools
  def call(%{"skill" => name, "prompt" => prompt}) do
    # Soft-gating: when max depth is reached, still run the skill but strip
    # its ability to call other skills (mirrors the researcher pattern).
    can_recurse? =
      case Services.SkillDepth.inc_depth() do
        {:ok, _depth} -> true
        {:error, :max_depth_reached} -> false
      end

    try do
      resolve_and_run(name, prompt, not can_recurse?)
    after
      case can_recurse? do
        true -> Services.SkillDepth.dec_depth()
        false -> :ok
      end
    end
  end

  # Try fnord TOML skills first, then fall through to external SKILL.md skills.
  defp resolve_and_run(name, prompt, strip_skills?) do
    case Skills.get_enabled(name) do
      {:ok, resolved} ->
        with :ok <- enforce_rw_gating(resolved) do
          run_skill(resolved, prompt, strip_skills?)
        end

      {:error, :not_found} ->
        case find_external_skill(name) do
          {:ok, ext_skill} -> run_external_skill(ext_skill, prompt, strip_skills?)
          {:error, :not_found} -> {:error, :not_found}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp enforce_rw_gating(%{effective: %{skill: %Skills.Skill{tools: tools}}}) do
    if Enum.member?(tools, "rw") and not Settings.get_edit_mode() do
      {:error, {:denied, "Cannot run rw skills; the user did not pass --edit."}}
    else
      :ok
    end
  end

  defp run_skill(%{effective: %{skill: skill}}, prompt, strip_skills?) do
    agent = AI.Agent.new(AI.Agent.Skill)

    AI.Agent.get_response(agent, %{
      skill: skill,
      prompt: prompt,
      strip_skills?: strip_skills?
    })
  end

  # Find an external (claude or cursor) skill by name in the enabled sources
  # for the current project.
  defp find_external_skill(name) do
    enabled_external_skills()
    |> Enum.find(&(&1.name == name))
    |> case do
      nil -> {:error, :not_found}
      skill -> {:ok, skill}
    end
  end

  # Synthesize a Skills.Skill from an ExternalConfigs.Skill and run it as a
  # sub-agent. External skills don't specify model/tools, so we use
  # conservative defaults; their SKILL.md body becomes the system prompt.
  defp run_external_skill(%ExternalConfigs.Skill{} = ext_skill, prompt, strip_skills?) do
    skill = %Skills.Skill{
      name: ext_skill.name,
      description: ext_skill.description || "",
      model: "balanced",
      tools: ["basic"],
      system_prompt: ext_skill.body,
      response_format: nil
    }

    agent = AI.Agent.new(AI.Agent.Skill)

    AI.Agent.get_response(agent, %{
      skill: skill,
      prompt: prompt,
      strip_skills?: strip_skills?
    })
  end

  @impl AI.Tools
  def ui_note_on_request(%{"skill" => skill}) do
    {"Run skill", skill}
  end

  @impl AI.Tools
  def ui_note_on_result(_args, _result) do
    nil
  end

  @impl AI.Tools
  def tool_call_failure_message(_args, _error) do
    :default
  end
end
