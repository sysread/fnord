defmodule Skills.Runtime do
  @moduledoc """
  Runtime helpers for executing skills.

  This module owns the glue between skill definitions (TOML) and the runtime
  components used to execute them:

  - model preset parsing (skill `model` string -> `AI.Model.t()`)
  - tool tag mapping (skill `tools` -> `AI.Tools.toolbox()`)
  - response_format validation

  Keeping these helpers in one place avoids duplicating the execution rules
  between the agent (`AI.Agent.Skill`) and the tool entry points.
  """

  @type model_error :: {:unknown_model_preset, String.t()}

  @type tool_tag :: String.t()

  @type toolbox_error ::
          {:unknown_tool_tag, tool_tag}
          | {:missing_basic_tool_tag, [tool_tag]}

  @type response_format_error ::
          {:invalid_response_format, term()}
          | {:missing_response_format_type, map()}

  @doc """
  Resolve a model preset string (from skill TOML) into an `AI.Model` struct.

  Supported values:
  - `smart`
  - `balanced`
  - `fast`
  - `web`
  - `large_context`
  - `large_context:<speed>` where speed is `smart|balanced|fast`

  The plain `large_context` form preserves the default behavior by calling
  `AI.Model.large_context/0`.
  """
  @spec model_from_string(String.t()) :: {:ok, AI.Model.t()} | {:error, model_error}
  def model_from_string(model) when is_binary(model) do
    case String.split(model, ":", parts: 2) do
      ["smart"] -> {:ok, AI.Model.smart()}
      ["balanced"] -> {:ok, AI.Model.balanced()}
      ["fast"] -> {:ok, AI.Model.fast()}
      ["web"] -> {:ok, AI.Model.web_search()}
      ["large_context"] -> {:ok, AI.Model.large_context()}
      ["large_context", speed] -> large_context_with_speed(speed)
      _ -> {:error, {:unknown_model_preset, model}}
    end
  end

  defp large_context_with_speed(speed) do
    case speed do
      "smart" -> {:ok, AI.Model.large_context(:smart)}
      "balanced" -> {:ok, AI.Model.large_context(:balanced)}
      "fast" -> {:ok, AI.Model.large_context(:fast)}
      _ -> {:error, {:unknown_model_preset, "large_context:#{speed}"}}
    end
  end

  @allowed_tags ["basic", "frobs", "task", "coding", "web", "rw", "skills"]
  @stable_tag_order ["frobs", "task", "coding", "web", "rw", "skills"]

  @doc """
  Build a toolbox from skill tool tags.

  Tags are mapped to `AI.Tools.with_*` groupers. Toolbox construction is
  deterministic and ignores input order.

  The `basic` tag is required; it acts as the toolbox entrypoint.
  """
  @spec toolbox_from_tags([tool_tag]) :: {:ok, AI.Tools.toolbox()} | {:error, toolbox_error}
  def toolbox_from_tags(tags) when is_list(tags) do
    tags =
      tags
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    case Enum.find(tags, fn tag -> not Enum.member?(@allowed_tags, tag) end) do
      unknown_tag when is_binary(unknown_tag) ->
        {:error, {:unknown_tool_tag, unknown_tag}}

      nil ->
        if Enum.member?(tags, "basic") do
          tags
          |> build_toolbox_from_tags()
          |> then(&{:ok, &1})
        else
          {:error, {:missing_basic_tool_tag, tags}}
        end
    end
  end

  defp build_toolbox_from_tags(tags) do
    base = AI.Tools.basic_tools()

    # Apply tags in a stable order.
    Enum.reduce(stable_tag_order(), base, fn tag, toolbox ->
      if Enum.member?(tags, tag) do
        apply_tool_tag(tag, toolbox)
      else
        toolbox
      end
    end)
  end

  defp stable_tag_order(), do: @stable_tag_order

  defp apply_tool_tag(tag, toolbox) do
    case tag do
      "frobs" -> AI.Tools.with_frobs(toolbox)
      "task" -> AI.Tools.with_task_tools(toolbox)
      "coding" -> AI.Tools.with_coding_tools(toolbox)
      "web" -> AI.Tools.with_web_tools(toolbox)
      "rw" -> AI.Tools.with_rw_tools(toolbox)
      "skills" -> AI.Tools.with_skills(toolbox)
      _ -> raise "Unknown tool tag reached apply_tool_tag unexpectedly: #{tag}"
    end
  end

  @doc """
  Validate a response_format value from a skill.

  `nil` is allowed and means default text responses.

  When present, the response format must be a map and should include a `type`
  key.
  """
  @spec validate_response_format(nil | map()) ::
          {:ok, nil | map()} | {:error, response_format_error}
  def validate_response_format(nil), do: {:ok, nil}

  def validate_response_format(%{} = map) do
    case Map.get(map, "type") || Map.get(map, :type) do
      nil -> {:error, {:missing_response_format_type, map}}
      type when is_binary(type) and byte_size(type) > 0 -> {:ok, map}
      other -> {:error, {:invalid_response_format, other}}
    end
  end

  def validate_response_format(other), do: {:error, {:invalid_response_format, other}}
end
