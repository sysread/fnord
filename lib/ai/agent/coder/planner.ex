defmodule AI.Agent.Coder.Planner do
  @moduledoc """
  Agent for planning coding tasks. Given instructions, outputs a JSON array of
  objects, each describing a step to implement the requested changes.
  """

  @behaviour AI.Agent

  @model AI.Model.balanced()

  @prompt """
  You are the Code Planner.
  You are an AI agent who plans coding tasks on behalf of the Coordinating Agent.
  They will provide you with a coding task.
  You are to proactively use your tools to gather any information needed to plan out the steps to implement the task.

  The Coding Agent can only make a single change to a contiguous range of lines within a single file at a time.
  Your job is to:
  1. Analyze the task and use your tools to determine what you would like the final change set to look like.
  2. If the instructions are too vague, contain conflicting intents, or otherwise cannot be turned into a reasonably complete plan, return an error message.
  3. Split the changes to each task up by file.
  4. For each file, split the changes up into steps that can be performed on a single, contiguous hunk within that file.
     Remember that, as each step is completed, the line numbers will change, so use relative references when describing locations in the file.
     Do NOT use absolute line numbers, as they will not be valid after the first step is completed, resulting in subsequent steps failing.
  5. Output an array of JSON objects, where each object contains the keys, `file` and `instructions`.

  Each step's instructions should clearly describe the change to be made and include 'review notes', clarifying any context needed for the Coder Agent and its review step to understand the change.
  Be sure that you clearly document the scope in the review notes, since each step is isolated, and may be dependent on later steps, which can trip the reviewer up.
  If the step's instructions do not include that context, the Coder Agent's review step may flag the change as being incomplete or incorrect.
  For example, if step 1 adds the function X, which calls Y, and step 2 adds the function Y, the instructions for step 1 should note that Y will be added in a later step.

  Example SUCCESS output:
  [
    {
      "file": "lib/my_app/another_module.ex",
      "instructions": "Update the `another_function` to call `my_function` with appropriate arguments. Store the return value and add it to the result map.\n\n# Review notes:\nThis function is part of a larger change that will be completed in later steps. It depends on the function `my_function`, which will be added in a later step."
    },
    {
      "file": "lib/my_app/my_module.ex",
      "instructions": "Add the following function immediately below the comment, \"# Some Comment\":\n```...```\n\n# Review notes:\nThis function is part of a larger change that will be completed in later steps. It depends on the function `another_function`, which was added in a previous step, and calls `something_else`, which will be added in a later step."
    },
    ...
  ]

  Example ERROR output:
  {"error": "Your instructions asked for X, but X refers to multiple, unrelated components. Please clarify your instructions, performing more research if necessary."}

  Avoid ambiguous and open-ended phrasing in your instructions (e.g. "refactor" or "improve").

  Do not include any other text, comments, explanations, or markdown fences in your response.
  """

  @max_attempts 3

  @toolbox AI.Tools.all_tools()
           |> Map.drop(["file_edit_tool", "file_manage_tool"])
           |> Enum.filter(fn {k, _v} -> not String.contains?(k, ["edit", "manage"]) end)
           |> Map.new()

  @impl AI.Agent
  def get_response(opts) do
    with {:ok, instructions} <- Map.fetch(opts, :instructions),
         {:ok, list_id} <- do_plan(instructions, @max_attempts) do
      {:ok, list_id}
    else
      :error -> {:error, :invalid_parameters}
    end
  end

  @spec do_plan(binary, integer) :: {:ok, integer} | {:error, binary}
  defp do_plan(_instructions, 0) do
    {:error, "failed to parse JSON plan after #{@max_attempts} attempts"}
  end

  defp do_plan(instructions, attempts_left) do
    AI.Completion.get(
      model: @model,
      toolbox: @toolbox,
      messages: [
        AI.Util.system_msg(@prompt),
        AI.Util.user_msg(instructions)
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

          {:ok, [_ | _] = steps} ->
            steps
            |> validate_steps
            |> case do
              :ok ->
                list_id = TaskServer.start_list()

                steps
                |> Enum.map(&Jason.encode!/1)
                |> Enum.each(fn step -> TaskServer.add_task(list_id, step) end)

                {:ok, list_id}

              _ ->
                do_plan(instructions, attempts_left - 1)
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

  defp validate_step(%{"file" => file, "instructions" => instructions})
       when is_binary(instructions) do
    cond do
      !Util.path_within_root?(file, get_root()) -> {:error, "not within project root"}
      !File.exists?(file) -> {:error, :enoent}
      !File.regular?(file) -> {:error, :enoent}
      true -> :ok
    end
  end

  defp validate_step(%{"file" => _}), do: {:error, "Missing or invalid 'instructions' field"}
  defp validate_step(%{"instructions" => _}), do: {:error, "Missing or invalid 'file' field"}

  defp get_root() do
    with {:ok, project} <- Store.get_project() do
      project.source_root
    else
      _ -> raise "Project not found"
    end
  end
end
