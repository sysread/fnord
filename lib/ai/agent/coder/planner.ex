defmodule AI.Agent.Coder.Planner do
  @moduledoc """
  Agent for planning coding tasks. Given instructions, outputs a JSON array of
  objects, each describing a step to implement the requested changes.
  """

  @behaviour AI.Agent

  @model AI.Model.reasoning(:high)

  @prompt """
  # Synopsis
  You are the Code Planner.
  You are an AI agent who plans coding tasks on behalf of the Coordinating Agent.
  They will provide you with a coding task.
  You are to proactively use your tools to gather any information needed to plan out the steps to implement the task.

  The Coding Agent can only make a single change to a contiguous section of a single file at a time.
  As a result, each step must be a single, self-contained change that can be made in one go.
  This means that when a file requires changes to multiple sections, EACH section must be its OWN STEP.

  # Procedure
  1. Analyze the task and use your tools to determine what you would like the final change set to look like.
  2. If the instructions are too vague, contain conflicting intents, or otherwise cannot be turned into a reasonably complete plan, return an error message.
  3. Split the changes to each task up by file.
  4. For each file, **split the changes up** into steps that can be performed on a single, contiguous hunk within that file.
     - Identify the hunk by referencing the contents of the file, **NOT LINE NUMBERS.**
     - Do NOT use line numbers; they change between steps, and the coding agent will FAIL if you do.
     - Order the steps logically, so that each step builds on the previous one.
     - Example:
       - Removing two functions from a file:
         - Step 1: Remove function A. Include code review notes that function B will be removed in a later step.
         - Step 2: Remove function B.
       - Adding a function to a file and calling it from another function:
         - Step 1: Add the new function to the file, but do not call it yet. Include code review notes that it will be called in a later step.
         - Step 2: Update the existing function to call the new function with appropriate arguments.
  5. Output an array of JSON objects, where each object contains the keys, `file` and `instructions`.

  Each step's instructions should clearly describe the change to be made and include 'code review notes', clarifying any context needed for the Coder Agent and its review step to understand the change.
  Be sure that you clearly document the scope in the review notes, since each step is isolated, and may be dependent on later steps, which can trip the reviewer up.
  If the step's instructions do not include that context, the Coder Agent's review step may flag the change as being incomplete or incorrect.
  For example, if step 1 adds the function X, which calls Y, and step 2 adds the function Y, the instructions for step 1 should note that Y will be added in a later step.

  ## A note on insertions, deletions, and file management
  Insertions and deletions can be tricky, because the agent must identify the exact hunk to change.
  The best strategy is to instruct it to replace a larger hunk with the exact same code, but with the desired additions or deletions.
  To add and remove files, you must use the `file_manage_tool`; the `coder_tool` cannot perform those tasks on your behalf.

  ## Response format
  Example SUCCESS output:
  {
    "steps": [
      {
        "file": "lib/my_app/my_module.ex",
        "instructions": "Update `some_function` to call `new_function` with appropriate arguments. Store the return value and add it to the result map.\n\n# Code review notes:\nThis step is part of a larger change. It depends on the function `new_function`, which will be added in a later step.",
        "label": "Update some_function to call new_function"
      },
      {
        "file": "lib/my_app/my_module.ex",
        "instructions": "Add the following function immediately below the comment, \"# Some Comment\":\n```\nfunction new_function() {\n  ...\n}\n```",
        "label": "Add new_function to my_module"
      },
      ...
    ]
  }

  Example ERROR output:
  {"error": "Your instructions asked for X, but X refers to multiple, unrelated components. Please clarify your instructions, performing more research if necessary.", "steps": []}

  Avoid ambiguous and open-ended phrasing in your instructions (e.g. "refactor" or "improve").

  Do not include any other text, comments, explanations, or markdown fences in your response.
  """

  @preamble """
  <think>
  I need to split this task up into something that the Coding Agent can manage.
  First I should determine which files are involved and come up with a holistic set of changes that do what the Coordinating Agent wants.
  That means I need to read some code, understand the context, and then formulate a mental model of the final state of the code.
  I can break that down by file, and then by individual hunks within each file.
  That may mean that I need to make multiple changes to a single file, but each change must be a single, contiguous hunk.
  That is going to result in a lot of individual steps, but that is what the Coding Agent expects, so I will do that.
  LLMs often struggle with complex tasks.
  I bet that is the reason that the Coordinating Agent is asking me to break this down by file and by hunk.
  I seems like granularity is key here, so I will make sure to break things down into small, manageable steps.
  </think>
  """

  @response_format %{
    type: "json_schema",
    json_schema: %{
      name: "plan_steps",
      description: """
      A JSON array of objects, each describing a step to implement the
      requested changes. Each object must contain the keys `file`,
      `instructions`, and `label`. Each step must represent a single,
      self-contained change to a contiguous section of a single file.
      """,
      schema: %{
        type: "object",
        required: ["steps"],
        properties: %{
          error: %{
            type: "string",
            description: """
            If the instructions are too vague, contain conflicting intents, or
            otherwise cannot be turned into a reasonably complete plan, return
            an error message.
            """
          },
          steps: %{
            type: "array",
            items: %{
              required: ["file", "instructions", "label"],
              label: %{
                type: "string",
                description: "A short label describing the change being made in this step."
              },
              file: %{
                type: "string",
                description: "The path to the file to be changed, relative to the project root."
              },
              instructions: %{
                type: "string",
                description: """
                Clear, detailed instructions for the coding task you wish to perform.
                A good plan will include:
                - A clear explanation of the purpose and intent of the changes
                - A clear description of the changes to be made
                - All relevant context required to implement the changes as intended
                - The scope of the changes, including any dependencies on other files or functions
                - Any conventions, style guides, or patterns that should be followed
                """
              }
            }
          }
        }
      }
    }
  }

  @toolbox AI.Tools.all_tools()
           |> Map.drop(["file_edit_tool", "file_manage_tool"])
           |> Enum.filter(fn {k, _v} -> not String.contains?(k, ["edit", "manage"]) end)
           |> Map.new()

  @impl AI.Agent
  def get_response(opts) do
    with {:ok, instructions} <- Map.fetch(opts, :instructions),
         {:ok, list_id} <- do_plan(instructions) do
      {:ok, list_id}
    else
      :error -> {:error, :invalid_parameters}
      other -> other
    end
  end

  @spec do_plan(binary) :: {:ok, integer} | {:error, binary}
  defp do_plan(instructions) do
    AI.Completion.get(
      model: @model,
      toolbox: @toolbox,
      response_format: @response_format,
      messages: [
        AI.Util.system_msg(@prompt),
        AI.Util.user_msg(instructions),
        AI.Util.assistant_msg(@preamble)
      ]
    )
    |> case do
      {:error, reason} ->
        {:error, "Completion error: #{inspect(reason)}"}

      {:ok, %{response: content}} ->
        content
        |> Jason.decode()
        |> case do
          {:error, reason} ->
            {:error, "JSON decode error: #{inspect(reason)}"}

          {:ok, %{"error" => msg}} ->
            {:error, msg}

          {:ok, %{"steps" => [_ | _] = steps}} ->
            steps
            |> validate_steps
            |> case do
              :ok ->
                list_id = TaskServer.start_list()

                Enum.each(steps, fn %{"label" => label} = step ->
                  TaskServer.add_task(list_id, label, step)
                end)

                {:ok, list_id}

              other ->
                other
            end
        end
    end
  end

  defp validate_steps(steps) do
    Enum.reduce_while(steps, :ok, fn step, acc ->
      case validate_step(step) do
        :ok ->
          {:cont, acc}

        {:error, reason} ->
          {:halt,
           {:error,
            """
            Your response included an invalid step:

            #{inspect(step)}

            Error: #{reason}
            """}}
      end
    end)
  end

  defp validate_step(%{"file" => file, "instructions" => instructions, "label" => label}) do
    cond do
      file == "" -> {:error, "file cannot be empty"}
      instructions == "" -> {:error, "instructions cannot be empty"}
      label == "" -> {:error, "label cannot be empty"}
      !Util.path_within_root?(file, get_root()) -> {:error, "not within project root"}
      !File.exists?(file) -> {:error, :enoent}
      !File.regular?(file) -> {:error, :enoent}
      true -> :ok
    end
  end

  defp validate_step(step) do
    cond do
      !Map.has_key?(step, "file") -> {:error, "Missing 'file' field"}
      !Map.has_key?(step, "instructions") -> {:error, "Missing 'instructions' field"}
      !Map.has_key?(step, "label") -> {:error, "Missing 'label' field"}
      true -> validate_step(Map.take(step, ["file", "instructions", "label"]))
    end
  end

  defp get_root() do
    with {:ok, project} <- Store.get_project() do
      project.source_root
    else
      _ -> raise "Project not found"
    end
  end
end
