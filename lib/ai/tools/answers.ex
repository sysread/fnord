defmodule AI.Tools.Answers do
  @moduledoc """
  This tool generates a response to the user using a template that is
  appropriate for the user's query.

  This module is configuration-based. `data/answers.yaml` defines a number of
  prompts with response templates geared toward different kinds of responses.
  For example, a code walk-through versus a operational playbook.

  The orchestrating agent selects the appropriate response template based on
  the user's query and the research and then calls this tool to generate the
  response using that template.

  Note that `data/answers.yaml` is read at *compile time* and is not itself a
  part of the release binary.
  """

  @agents_file "data/answers.yaml"
  @external_resource @agents_file
  @agent_defs YamlElixir.read_from_file!(@agents_file)

  @agents @agent_defs |> Enum.map(& &1["name"])
  @agent @agent_defs |> Enum.map(&{&1["name"], &1}) |> Map.new()

  def agent_names(), do: @agents

  def agent_description(%{"name" => name, "description" => description}) do
    "- #{name}: #{description}"
  end

  def agent_description_list() do
    @agent_defs
    |> Enum.map(&agent_description/1)
    |> Enum.join("\n")
  end

  # -----------------------------------------------------------------------------
  # Behaviour implementation
  # -----------------------------------------------------------------------------
  @behaviour AI.Tools

  @model AI.Model.smart()

  @non_git_tools [
    AI.Tools.tool_spec!("file_contents_tool"),
    AI.Tools.tool_spec!("file_info_tool"),
    AI.Tools.tool_spec!("file_list_tool"),
    AI.Tools.tool_spec!("file_search_tool"),
    AI.Tools.tool_spec!("file_spelunker_tool"),
    AI.Tools.tool_spec!("notes_search_tool")
  ]

  @git_tools [
    AI.Tools.tool_spec!("git_diff_branch_tool"),
    AI.Tools.tool_spec!("git_list_branches_tool"),
    AI.Tools.tool_spec!("git_log_tool"),
    AI.Tools.tool_spec!("git_pickaxe_tool"),
    AI.Tools.tool_spec!("git_show_tool")
  ]

  @tools @non_git_tools ++ @git_tools

  @impl AI.Tools
  def ui_note_on_request(%{"agent" => agent}) do
    {"Generating a response", "#{agent}"}
  end

  @impl AI.Tools
  def ui_note_on_result(_completion, _args), do: nil

  @impl AI.Tools
  def read_args(args) do
    with {:ok, agent} <- read_agent(args) do
      {:ok, %{"agent" => agent}}
    end
  end

  defp read_agent(%{"agent" => agent}) when agent in @agents, do: {:ok, agent}
  defp read_agent(%{"agent" => _}), do: {:error, :invalid_argument, "agent"}
  defp read_agent(_), do: {:error, :missing_argument, "agent"}

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "answers_tool",
        description: """
        Directs one of the following AI Agents to build a response for the user's query.
        The Agent will receive a full transcript of all of the research performed thus far.
        Each Agent is customized to provide the optimal response format for a class of user query.
        """,
        strict: true,
        parameters: %{
          additionalProperties: false,
          type: "object",
          required: ["agent"],
          properties: %{
            agent: %{
              type: "string",
              description: """
              The name of the Agent to use to build the response. MUST be one of the following:
              #{agent_description_list()}
              """
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(%{messages: messages}, %{"agent" => agent}) do
    with {:ok, %{response: response}} <- get_response(agent, messages) do
      {:ok, response}
    end
  end

  # ----------------------------------------------------------------------------
  # Private functions
  # ----------------------------------------------------------------------------
  defp get_response(agent, messages) do
    with {:ok, agent} <- Map.fetch(@agent, agent),
         {:ok, prompt} <- Map.fetch(agent, "prompt") do
      transcript = AI.Util.research_transcript(messages)
      question = AI.Util.user_query(messages)

      AI.Completion.get(AI.new(),
        model: @model,
        use_planner: false,
        log_msgs: false,
        log_tool_calls: false,
        tools: available_tools(),
        messages: [
          AI.Util.system_msg(prompt),
          AI.Util.user_msg("""
          Never refer to the "transcript".
          Call it the "research" instead.

          The following is a transcript of the research performed:
          -----
          #{transcript}
          -----

          The user asked:
          > #{question}
          """)
        ]
      )
    end
  end

  defp available_tools() do
    if Git.is_git_repo?() do
      @tools
    else
      @non_git_tools
    end
  end
end
