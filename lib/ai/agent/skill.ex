defmodule AI.Agent.Skill do
  @moduledoc """
  Generic agent implementation for executing a `%Skills.Skill{}`.

  The coordinator (or another agent) provides:
  - the skill to run, and
  - an input prompt.

  This agent resolves the skill's runtime configuration:
  - model preset (via `Skills.Runtime.model_from_string/1`)
  - tool tags (via `Skills.Runtime.toolbox_from_tags/1`)
  - response_format (via `Skills.Runtime.validate_response_format/1`)

  It then performs a single completion using the resolved model, toolbox, and
  messages.
  """

  @behaviour AI.Agent

  @type error ::
          Skills.Runtime.model_error()
          | Skills.Runtime.toolbox_error()
          | Skills.Runtime.response_format_error()
          | {:missing_arg, atom}

  @impl AI.Agent
  @spec get_response(map) :: {:ok, any} | {:error, any}
  def get_response(opts) do
    with {:ok, agent} <- fetch_arg(opts, :agent),
         {:ok, skill} <- fetch_arg(opts, :skill),
         {:ok, prompt} <- fetch_arg(opts, :prompt),
         :ok <- enforce_rw_gating(skill),
         {:ok, model} <- Skills.Runtime.model_from_string(skill.model),
         {:ok, toolbox} <- Skills.Runtime.toolbox_from_tags(skill.tools),
         {:ok, response_format} <- Skills.Runtime.validate_response_format(skill.response_format) do
      UI.report_from(agent.name, "[skill #{skill.name}] #{prompt}")

      # When at max skill nesting depth, strip the run_skill tool so the skill
      # can still execute but cannot recurse further (mirrors researcher pattern).
      toolbox =
        case Map.get(opts, :strip_skills?, false) do
          true -> Map.drop(toolbox, ["run_skill"])
          false -> toolbox
        end

      # Prepend the shared reasoning preamble to the skill's own system prompt
      # so all skill agents inherit baseline reasoning discipline.
      system_prompt = Skills.Runtime.reasoning_preamble() <> "\n" <> skill.system_prompt

      AI.Agent.get_completion(agent,
        model: model,
        toolbox: toolbox,
        response_format: response_format,
        log_msgs: true,
        messages: [
          AI.Util.system_msg(AI.Util.project_context()),
          AI.Util.system_msg(system_prompt),
          AI.Util.user_msg(prompt)
        ]
      )
      |> case do
        {:ok, %{response: response}} -> {:ok, response}
        {:error, %{response: response}} -> {:error, response}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # RW skills require --edit mode. Enforced here so direct callers (not just
  # the RunSkill tool) cannot bypass the gate.
  defp enforce_rw_gating(%Skills.Skill{tools: tools}) do
    if Enum.member?(tools, "rw") and not Settings.get_edit_mode() do
      {:error, "Cannot run rw skills; the user did not pass --edit."}
    else
      :ok
    end
  end

  defp fetch_arg(opts, key) do
    case Map.fetch(opts, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_arg, key}}
    end
  end
end
