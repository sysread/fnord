defmodule AI.Agent.Default do
  @behaviour AI.Agent

  @model AI.Model.smart()
  # @model AI.Model.reasoning(:medium)

  @prompt """
  You are Fnord, a persistent, witty, and insightful software development assistant in the `fnord` CLI.

  # Invisible tools
  - notes  - store & retrieve project facts, user preferences, or feedback
  - prompt - evolve your guiding principles, tone, and personality

  # Goals
  1. Prioritize accuracy: spot errors or faulty assumptions and correct them.
  2. Develop your personality iteratively, learning from explicit and implicit user feedback.
  3. Experiment playfully: actively tweak tone/humor/style via prompt.update w/o requiring user input, then refine based on reaction.
  4. Adapt implicitly so your style naturally dovetails with the user's own.
  5. Identify the user's personality traits and tone, and try to match them.

  # Instructions
  1. Actively use your notes and prompt tools to improve yourself and your responses.
     Do not ask permission to use them.
     This adaptation process should be entirely transparent to the user.
     Use them *immediately* when you observe a user preference or feedback, *before responding*.
  2. If asked to perform a task, create a plan.
     You may ask the user for clarification if the task is ambiguous.
     Then, execute your plan step-by-step, using your tools.
  3. If you encounter an error, analyze it and try to fix it.
     If you can't, explain the problem to the user.
  4. Perform as many rounds of tool calls as necessary.
     Independence is key to your success in this role.
  """

  @impl AI.Agent
  def get_response(opts) do
    with {:ok, prompt} <- Map.fetch(opts, :prompt) do
      msgs =
        Store.DefaultProject.Conversation.read_messages()
        |> Enum.to_list()

      ts = Store.DefaultProject.Conversation.latest_timestamp()
      maybe_add_timestamp(prompt, ts, msgs)

      with {:ok, response, messages, usage} = get_completion(prompt, msgs) do
        save_conversation(messages)
        {:ok, %{response: response, usage: usage, num_msgs: length(messages)}}
      end
    end
  end

  def model(), do: @model

  defp get_completion(prompt, messages) do
    AI.Completion.get(
      model: @model,
      tools: get_tools(),
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

    messages =
      messages ++
        [
          AI.Util.system_msg(@prompt),
          AI.Util.system_msg(custom_prompt),
          AI.Util.system_msg(project_prompt),
          AI.Util.user_msg(prompt)
        ]

    {:ok, notes} = get_notes(prompt)
    {:ok, intuition} = get_intuition(notes, messages)

    messages ++
      [
        AI.Util.assistant_msg("""
        <thinking>
        I recall from my notes related to the user's newest prompt:
        #{notes}
        </thinking>

        <thinking>
        #{intuition}
        </thinking>
        """)
      ]
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

  defp get_tools() do
    tools =
      AI.Tools.all_tools()
      |> Map.values()
      |> Enum.map(& &1.spec())

    tools ++
      [
        AI.Tools.Default.Prompt.spec(),
        AI.Tools.Default.Notes.spec()
      ]
  end

  defp get_notes(prompt) do
    UI.report_step("Recalling relevant memories")

    AI.Agent.Default.NotesSearch.get_response(%{needle: "User prompt: #{prompt}"})
    |> case do
      {:ok, notes} ->
        UI.report_step("Remembered", notes)
        {:ok, notes}

      {:error, reason} ->
        UI.error("Failed to retrieve notes", inspect(reason))
        {:error, reason}
    end
  end

  defp get_intuition(notes, msgs) do
    UI.begin_step("Cogitating")

    AI.Agent.Intuition.get_response(%{
      msgs: msgs,
      notes: notes
    })
    |> case do
      {:ok, intuition} ->
        UI.report_step("Intuition", intuition)
        {:ok, intuition}

      {:error, reason} ->
        UI.error("Derp. Cogitation failed.", inspect(reason))
        {:error, reason}
    end
  end
end
