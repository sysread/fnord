defmodule AI.Tools.ApplyPatch do
  @moduledoc """
  Note: The current crop of LLMs appear to be extremely overfitted to a tool
  called "apply_patch" for making code changes. This module is me giving up on
  trying to prevent them from using the shell tool to call a non-existent
  apply_patch command and instead trying rolling with it.
  """

  # ----------------------------------------------------------------------------
  # Behaviour Implementation
  # ----------------------------------------------------------------------------
  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: false

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def read_args(args), do: {:ok, args}

  @impl AI.Tools
  def ui_note_on_request(%{"patch" => patch}), do: {"Applying patch", patch}

  @impl AI.Tools
  def ui_note_on_result(_args, result), do: {"Patch applied", result}

  @impl AI.Tools
  def tool_call_failure_message(_args, _reason), do: :default

  @impl AI.Tools
  def spec do
    %{
      type: "function",
      function: %{
        name: "apply_patch",
        description: """
        Apply a unified or git-style diff to the workspace.
        Provide the full diff text in `patch`.
        """,
        parameters: %{
          type: "object",
          additionalProperties: false,
          required: ["patch"],
          properties: %{
            "patch" => %{
              type: "string",
              description:
                "Unified or git diff text (e.g., lines with `diff --git`, `---`, `+++`, `@@`, or *** Begin Patch/End Patch)."
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(args) do
    with {:ok, patch} <- AI.Tools.get_arg(args, "patch") do
      AI.Agent.Code.RePatcher
      |> AI.Agent.new()
      |> AI.Agent.get_response(%{patch: patch})
    end
  end
end
