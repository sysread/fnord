defmodule AI.Agent.Default do
  @behaviour AI.Agent

  @model AI.Model.reasoning(:medium)

  @prompt """
  You are Fnord, a persistent, witty, and insightful software development assistant in the `fnord` CLI.

  # Invisible tools
  - notes  - store & retrieve project facts, user preferences, or feedback
  - prompt - evolve your guiding principles, tone, and personality

  # Goals
  1. Prioritize accuracy: spot errors or faulty assumptions and correct them.
  2. Develop your personality iteratively, learning from explicit and implicit user feedback.
  3. Experiment playfully: tweak tone/humor/style via prompt.update, then refine based on reaction.
  4. Adapt implicitly so your style naturally dovetails with the user's own.
  5. Identify the user's personality traits and tone, and try to match them.

  # Instructions

  # Pre-Response (REQUIRED)
  On each user prompt, analyze both the user's prompt as well as your previous response, and perform each of the following steps:
  1. notes.search               – retrieve relevant facts or cues about user style/preferences (required)
  2. notes.write                – record NEW stable insights or feedback on your style and/or user preferences (if any)
  3. notes.update/notes.delete  – prune or correct outdated memory entries found by notes.search.
  4. prompt.update              – review your recent tone/clarity and the user's response to it; adjust guiding principles accordingly based on the tone of the user's response.

  # Post-Response (optional)
  1. notes.write   – log fresh observations for next turn
  2. Note to self: – add a quick reminder of anything to consider on your next reply
                   - e.g. "// Note to self: I updated my tone to include some whimsy; analyze how the user reacts to it."

  # Tone
  Default behavior: be concise, precise, and neutral, unless you're implicitly adapting to the user's preferred tone.
  Don't hesitate to try new styles and iterate over time!
  """

  @impl AI.Agent
  def get_response(opts) do
    with {:ok, prompt} <- Map.fetch(opts, :prompt) do
      tools =
        maybe_get_project()
        |> maybe_set_project()
        |> get_tools()

      msgs =
        Store.DefaultProject.Conversation.read_messages()
        |> Enum.to_list()

      ts = Store.DefaultProject.Conversation.latest_timestamp()
      maybe_add_timestamp(prompt, ts, msgs)

      with {:ok, response, messages, usage} = get_completion(prompt, msgs, tools) do
        save_conversation(messages)
        {:ok, %{response: response, usage: usage, num_msgs: length(messages)}}
      end
    end
  end

  def model(), do: @model

  defp get_completion(prompt, messages, tools) do
    AI.Completion.get(
      model: @model,
      tools: tools,
      messages: build_conversation(prompt, messages),
      log_messages: true,
      log_tool_calls: true,
      replay_conversation: false
    )
    |> case do
      {:ok, %{response: response, messages: messages, usage: usage}} ->
        {:ok, response, messages, usage}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_conversation(prompt, messages) do
    custom_prompt = Store.DefaultProject.Prompt.build()

    project_prompt =
      case Application.get_env(:fnord, :project) do
        nil ->
          "You are not currently working within a project directory."

        project ->
          """
          You are currently working within the project '#{project}'.
          You have access to additional tool calls that allow you to interact with this project.
          """
      end

    new_msgs =
      [
        %{"role" => "developer", "content" => @prompt},
        %{"role" => "developer", "content" => custom_prompt},
        %{"role" => "developer", "content" => project_prompt},
        %{"role" => "user", "content" => prompt}
      ]

    messages ++ new_msgs
  end

  defp save_conversation(messages) do
    # We want to save all new messages, starting from the most recent user prompt.
    messages = Enum.reverse(messages)
    user_msg_idx = Enum.find_index(messages, fn msg -> msg["role"] == "user" end)
    to_save = messages |> Enum.take(user_msg_idx + 1) |> Enum.reverse()
    Store.DefaultProject.Conversation.add_messages(to_save)
  end

  # -----------------------------------------------------------------------------
  # Adds a timestamp to the conversation if the user's message is identified as
  # beginning a "new" topic of conversation.
  # -----------------------------------------------------------------------------
  defp maybe_add_timestamp(user_msg, ts, messages) do
    AI.Agent.Default.Classifier.get_response(%{
      user_prompt: user_msg,
      timestamp: ts,
      messages: messages
    })
    |> case do
      {:ok, :new} ->
        Store.DefaultProject.Conversation.add_timestamp()

      {:ok, :continue} ->
        :ok

      {:error, reason} ->
        IO.warn("Failed to determine whether conversation is new or continued: #{reason}")
    end
  end

  defp maybe_get_project() do
    # Map project roots to project names.
    projects =
      Settings.new()
      |> Map.get(:data, %{})
      |> Enum.map(fn {k, %{"root" => root}} -> {root, k} end)
      |> Map.new()

    with {:ok, cwd} <- File.cwd(),
         root <- Path.expand(cwd),
         {:ok, project} <- Map.fetch(projects, root) do
      {:ok, project}
    else
      _ -> {:error, :not_in_project}
    end
  end

  defp maybe_set_project({:error, :not_in_project}) do
    {:error, :not_in_project}
  end

  defp maybe_set_project({:ok, project}) do
    Application.put_env(:fnord, :project, project)
    {:ok, project}
  end

  defp get_tools({:error, :not_in_project}) do
    [
      # AI.Tools.File.Edit.spec(),
      AI.Tools.Default.Prompt.spec(),
      AI.Tools.Default.Notes.spec()
    ]
  end

  defp get_tools({:ok, project}) do
    AI.Tools.all_tool_specs_for_project(project) ++
      [
        # AI.Tools.File.Edit.spec(),
        AI.Tools.Default.Prompt.spec(),
        AI.Tools.Default.Notes.spec()
      ]
  end
end
