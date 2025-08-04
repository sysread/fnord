defmodule AI.Tools.CoderAgent do
  @moduledoc """
  Tool for invoking the AI.Agent.Coder agent.

  This tool allows the coordinator to delegate milestone implementation 
  to the specialized coder agent, which manages its own task stack.
  """

  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: false

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def read_args(args) do
    with {:ok, instructions} <- AI.Tools.get_arg(args, "instructions"),
         {:ok, conversation_id} <- AI.Tools.get_arg(args, "conversation_id") do
      {:ok,
       %{
         "instructions" => instructions,
         "conversation_id" => conversation_id
       }}
    end
  end

  @impl AI.Tools
  def ui_note_on_request(%{"instructions" => instructions}) do
    # Extract milestone ID from instructions for cleaner display
    milestone_id =
      case Regex.run(~r/MILESTONE:\s*(\w+)/, instructions) do
        [_, id] -> id
        _ -> "milestone"
      end

    {"Executing Milestone", "Delegating #{milestone_id} to coder agent"}
  end

  @impl AI.Tools
  def ui_note_on_result(_args, result) do
    case String.contains?(result, "error") do
      true -> {"Milestone Failed", "Coder agent encountered errors"}
      false -> {"Milestone Completed", "Coder agent finished successfully"}
    end
  end

  @impl AI.Tools
  def spec do
    %{
      type: "function",
      function: %{
        name: "coder_tool",
        description: """
        Delegate milestone implementation to the specialized coder agent.

        The coder agent will:
        1. Analyze the milestone requirements
        2. Create its own task stack for the work
        3. Execute changes using its coding tools
        4. Validate the results

        Use this tool when you need to implement code changes for a specific milestone.
        """,
        strict: true,
        parameters: %{
          additionalProperties: false,
          type: "object",
          required: ["instructions", "conversation_id"],
          properties: %{
            instructions: %{
              type: "string",
              description: """
              Detailed instructions for the coder agent including:
              - MILESTONE: milestone identifier
              - DESCRIPTION: what needs to be delivered  
              - RATIONALE: why this milestone is separate
              - ORIGINAL REQUEST: the user's original request context
              """
            },
            conversation_id: %{
              type: "string",
              description: "The conversation ID to use for the coder agent"
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(%{"instructions" => instructions, "conversation_id" => conversation_pid}) when is_pid(conversation_pid) do
    agent_opts = %{
      instructions: instructions,
      conversation: conversation_pid
    }

    case AI.Agent.Coder.get_response(agent_opts) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        {:error, "Coder agent failed: #{reason}"}
    end
  end
end
