defmodule AI.Tools.Research do
  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: true

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def ui_note_on_request(%{"prompt" => prompt} = args) do
    project = get_project(args)
    {"Requesting research in #{project}", prompt}
  end

  @impl AI.Tools
  def ui_note_on_result(%{"prompt" => prompt} = args, result) do
    project = get_project(args)

    {"Research completed in #{project}",
     """
     # Request
     #{prompt}

     # Findings
     #{result}
     """}
  end

  @impl AI.Tools
  def tool_call_failure_message(_args, _reason), do: :default

  @impl AI.Tools
  def read_args(args), do: {:ok, args}

  @impl AI.Tools
  def spec() do
    current =
      case Settings.get_selected_project() do
        {:ok, project} -> project
        _ -> nil
      end

    projects =
      Settings.new()
      |> Settings.list_projects()
      |> Enum.map(fn project ->
        if project == current do
          "- #{project} (current)"
        else
          "- #{project}"
        end
      end)
      |> Enum.join("\n")

    %{
      type: "function",
      function: %{
        name: "research_tool",
        description: """
        **This is your research assistant.**

        Spin off a focused sub-research process to perform multiple lines of
        research in parallel, allowing you to gather information from multiple
        sources and synthesize findings into a hollistic view of the code base.

        Research is performed by another AI agent which has access to most of
        the same tools that you do to perform their task.

        The following projects are available for research:
        #{projects}

        !!! This is your most powerful tool !!!
        """,
        parameters: %{
          type: "object",
          required: ["prompt"],
          additionalProperties: false,
          properties: %{
            prompt: %{
              type: "string",
              description: """
              The research task to perform. This should be a specific question
              or task that you want the AI agent to research. Provide context
              as needed to clarify the task, as they will be starting from
              scratch with no context. The more explicit and clear you are, the
              more likely they are to produce useful results.
              """
            },
            fnord_project: %{
              type: "string",
              description: """
              By default, research is performed within the current project. If
              the user asks for you to cross-reference a different project,
              this option may be specified to indicate that the research should
              be performed in that project instead.

              Possible values:
              #{projects}
              """
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(%{"prompt" => prompt} = args) do
    with {:ok, selected_project} <- Settings.get_selected_project() do
      args
      |> get_project()
      |> case do
        ^selected_project -> do_research(prompt)
        project -> do_research(project, prompt)
      end
    end
  end

  defp do_research(prompt) do
    AI.Agent.Researcher
    |> AI.Agent.new()
    |> AI.Agent.get_response(%{prompt: prompt})
  end

  defp do_research(project, prompt) do
    fnord =
      :escript.script_name()
      |> Path.expand()
      |> Path.absname()

    System.cmd(
      fnord,
      ["ask", "--quiet", "--project", project, "--question", prompt],
      env: [
        {"LOGGER_LEVEL", "error"},
        {"FNORD_FORMATTER", ""}
      ],
      parallelism: true,
      stderr_to_stdout: true,
      into: ""
    )
    |> case do
      {output, 0} -> {:ok, output}
      {output, _} -> {:error, output}
    end
  end

  defp get_project(args) do
    args
    |> Map.get("fnord_project", nil)
    |> case do
      nil ->
        case Settings.get_selected_project() do
          {:ok, project} -> project
          _ -> raise "No project specified and no current project selected."
        end

      project ->
        project
    end
  end
end
