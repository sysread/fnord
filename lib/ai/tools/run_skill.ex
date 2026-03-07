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
    skills_desc = skills_description()

    %{
      name: @tool_name,
      description: "Run a named skill.\n\nAvailable skills:\n#{skills_desc}",
      parameters_schema: %{
        type: "object",
        properties: %{
          skill: %{
            type: "string",
            description: "Skill name. Available skills:\n#{skills_desc}"
          },
          prompt: %{
            type: "string",
            description: "Input prompt to send to the skill"
          }
        },
        required: ["skill", "prompt"]
      }
    }
  end

  defp skills_description() do
    Skills.list_enabled()
    |> case do
      {:ok, skills} when skills == [] ->
        "(none found)"

      {:ok, skills} ->
        skills
        |> Enum.map(fn %{name: name, effective: %{skill: skill}} ->
          "- #{name}: #{skill.description}"
        end)
        |> Enum.join("\n")

      {:error, reason} ->
        "(error loading skills: #{inspect(reason)})"
    end
  end

  @impl AI.Tools
  def call(%{"skill" => name, "prompt" => prompt}) do
    case Services.SkillDepth.inc_depth() do
      {:ok, _depth} ->
        try do
          with {:ok, resolved} <- Skills.get(name),
               :ok <- enforce_rw_gating(resolved),
               {:ok, response} <- run_skill(resolved, prompt) do
            {:ok, response}
          else
            {:error, reason} ->
              {:error, reason}
          end
        after
          Services.SkillDepth.dec_depth()
        end

      {:error, :max_depth_reached} ->
        {:error, {:max_skill_depth, Services.SkillDepth.depth()}}
    end
  end

  defp enforce_rw_gating(%{effective: %{skill: %Skills.Skill{tools: tools}}}) do
    if Enum.member?(tools, "rw") and not Settings.get_edit_mode() do
      {:error, {:denied, "Cannot run rw skills; the user did not pass --edit."}}
    else
      :ok
    end
  end

  defp run_skill(%{effective: %{skill: skill}}, prompt) do
    agent = AI.Agent.new(AI.Agent.Skill)

    AI.Agent.get_response(agent, %{
      skill: skill,
      prompt: prompt
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
