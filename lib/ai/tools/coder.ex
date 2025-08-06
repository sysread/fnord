defmodule AI.Tools.Coder do
  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: true

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def read_args(args), do: {:ok, args}

  @impl AI.Tools
  def ui_note_on_request(_args), do: nil

  @impl AI.Tools
  def ui_note_on_result(_args, _result), do: nil

  @impl AI.Tools
  def spec do
    %{
      type: "function",
      function: %{
        name: "coder_tool",
        description: """
        Plans, implements, and verifies changes to the code base.
        It is the responsibility of the Coordinating Agent to verify that the changes meet their needs once implemented.
        """,
        parameters: %{
          type: "object",
          required: ["requirements"],
          additionalProperties: false,
          properties: %{
            requirements: %{
              type: "string",
              description: """
              Detailed requirements for the code change.
              Must include:
              - Purpose of the change
              - Concrete functionality to be implemented
              - References to files, directories, components, and other relevant code elements
              - Clear acceptance criteria

              The more detail you can provide on the requirements, the better the outcome will be.
              """
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(args) do
    with {:ok, requirements} <- AI.Tools.get_arg(args, "requirements"),
         {:ok, task_list_id} <- AI.Agent.Code.Planner.get_response(%{request: requirements}),
         {:ok, _} <- AI.Agent.Code.TaskImplementor.get_response(%{task_list_id: task_list_id}) do
      {:ok,
       """
       # Requirements
       #{requirements}

       # Result
       #{TaskServer.as_string(task_list_id, true)}
       """}
    end
  end
end
