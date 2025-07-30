defmodule AI.Tools.Coder do
  @behaviour AI.Tools

  @doc """
  This tool relies on line numbers within individual files to identify ranges.
  If those numbers change between the time the range is identified and the time
  the changes are applied, the tool will fail to apply the changes correctly.
  """
  @impl AI.Tools
  def async?, do: false

  @impl AI.Tools
  def is_available?, do: AI.Tools.has_indexed_project()

  @impl AI.Tools
  def ui_note_on_request(%{"instructions" => instructions}) do
    {"Planning and implementing changes", instructions}
  end

  @impl AI.Tools
  def ui_note_on_result(%{"instructions" => instructions}, result) do
    {"Changes applied:",
     """
     # Instructions
     #{instructions}

     # Result
     #{result}
     """}
  end

  @impl AI.Tools
  def read_args(args), do: {:ok, args}

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "coder_tool",
        description: """
        Launches a collection of AI Agents to plan and implement code changes within the project.
        For the best results, provide clear, meticulously detailed instructions for the coding task.
        Instructions should include details about conventions, style, preferred modules and patterns, and anything else you wish to have reflected in the output.
        Instructions must include ALL relevant context; the agents have NO access to the prior conversation; they ONLY know what YOU tell them.
        If your instructions are ambiguous or unclear, this tool may not be able to generate a valid plan or implement the changes correctly.
        """,
        parameters: %{
          type: "object",
          required: ["instructions"],
          properties: %{
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
  end

  @impl AI.Tools
  def call(%{"instructions" => instructions}) do
    instructions
    |> code_stuff()
    |> case do
      {:ok, result} ->
        UI.info("Coding completed", result)
        {:ok, result}

      {:error, reason} ->
        UI.error("Coding failed", reason)

        {:error,
         """
         FAILURE: The coder_tool was unable to apply the requested changes. No changes were made to the file.
         #{reason}
         """}
    end
  end

  defp code_stuff(instructions) do
    with {:ok, list_id} <- plan_steps(instructions),
         :ok <- do_steps(list_id) do
      {:ok,
       list_id
       |> TaskServer.get_list()
       |> TaskServer.as_string(true)}
    end
  end

  defp plan_steps(instructions) do
    UI.info("Planning changes")

    with {:ok, list_id} <- AI.Agent.Coder.Planner.get_response(%{instructions: instructions}) do
      UI.info("Planning completed", TaskServer.as_string(list_id))
      {:ok, list_id}
    end
  end

  defp do_steps(list_id) do
    list_id
    |> TaskServer.get_list()
    |> do_steps(list_id)
  end

  defp do_steps(steps, list_id, acc \\ :ok)

  defp do_steps(remaining_steps, list_id, {:error, label, reason}) do
    msg = """
    The coding task failed at step: #{label}
    #{reason}
    """

    # Fail the remaining tasks in the list
    remaining_steps
    |> Enum.each(fn %{id: id} ->
      TaskServer.fail_task(list_id, id, "Cancelled due to failure at prior step: #{label}")
    end)

    {:error, msg}
  end

  defp do_steps([], _list_id, :ok), do: :ok

  defp do_steps([step | steps], list_id, :ok) do
    %{
      "label" => label,
      "file" => file,
      "instructions" => instructions
    } = step.data

    with {:ok, result} <- do_step(label, file, instructions) do
      UI.info("Step completed", label)
      TaskServer.complete_task(list_id, step.id, result)
      do_steps(list_id, steps, :ok)
    else
      {:error, reason} ->
        UI.warn("Step failed", label)
        TaskServer.fail_task(list_id, step.id, inspect(reason))
        do_steps(list_id, steps, {:error, label, reason})
    end
  end

  defp do_step(label, file, instructions) do
    UI.info("Performing coding task", label)

    with {:ok, {start_line, end_line}} <- identify_range(file, instructions),
         {:ok, replacement, preview} <- dry_run(file, instructions, start_line, end_line),
         :ok <- confirm_changes(file, instructions, preview),
         {:ok, result} <- apply_changes(file, start_line, end_line, replacement) do
      UI.info(
        "Coding task complete",
        """
        # #{label}
        Changes applied to #{file}:#{start_line}-#{end_line}.

        # Outcome
        #{result}
        """
      )

      {:ok, result}
    end
  end

  defp identify_range(file, instructions) do
    AI.Agent.Coder.RangeFinder.get_response(%{instructions: instructions, file: file})
    |> case do
      {:ok, {start_line, end_line}} ->
        UI.info("Hunk identified in #{file}", "Lines #{start_line}...#{end_line}")
        {:ok, {start_line, end_line}}

      {:identify_error, msg} ->
        {:error,
         """
         The agent was unable to identify a single, contiguous range of lines in the file based on the provided instructions:
         #{msg}
         """}

      other ->
        other
    end
  end

  defp dry_run(file, instructions, start_line, end_line) do
    %{file: file, instructions: instructions, start_line: start_line, end_line: end_line}
    |> AI.Agent.Coder.DryRun.get_response()
  end

  defp confirm_changes(file, instructions, preview) do
    %{file: file, instructions: instructions, preview: preview}
    |> AI.Agent.Coder.Reviewer.get_response()
    |> case do
      :ok ->
        UI.info("Reviewer approved changes", file)
        :ok

      {:confirm_error, error} ->
        UI.warn("Reviewer rejected changes to #{file}", error)

        {:error,
         """
         The code reviewing agent found an error in the requested change:
         #{error}
         """}

      other ->
        other
    end
  end

  defp apply_changes(file, start_line, end_line, replacement) do
    AI.Tools.File.Edit.call(%{
      "path" => file,
      "start_line" => start_line,
      "end_line" => end_line,
      "replacement" => replacement,
      "dry_run" => false,
      "context_lines" => 5
    })
  end
end
