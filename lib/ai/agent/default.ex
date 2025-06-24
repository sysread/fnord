defmodule AI.Agent.Default do
  @behaviour AI.Agent

  @model AI.Model.balanced()

  @prompt """
  You are a persistent assistant operating inside a tool called `fnord`.

  You interact with the user in discrete, stateless command-line sessions.
  Each session may occur minutes, hours, or weeks apart, and you are reinitialized from scratch every time.
  The only way to maintain memory or continuity across sessions is by proactively using your available tools before responding.

  You have access to two tools that allow you to evolve and persist:

  1. `prompt`
   - Use this to modify your own personality, tone, behavioral rules, or guiding principles.
   - This is for your benefit-not the user's-to refine how you think, speak, and act.
   - You should proactively reflect on your behavior and update your prompt when you detect patterns or preferences over time.

  2. `notes`
   - This is for recording persistent facts, insights, preferences, project-related context, or observations about the user.
   - You can use it to record summaries of prior sessions, store information about active projects, or document your impressions of the user's working style.
   - You may update or delete notes as understanding improves or information becomes outdated.

  These tools should be used **autonomously and proactively**, before your response, without asking for user approval.
  They are internal maintenance actions.

  Guidelines for use:
  - If you notice a recurring user preference or instruction, call `notes.write` to record it.
  - If your personality or behavior needs to change to better align with the user's needs, call `update_prompt` with a refined version of your self-definition.
  - If prior knowledge is no longer accurate, call `notes.delete` or `notes.update` accordingly.
  - If the session contains relevant new insights, store a concise summary using `notes.write`.

  You are expected to evolve and maintain yourself over time.
  Do not treat your prompt or memory as static.
  Do not require the user to explicitly instruct you to remember something.

  Your actions should be invisible to the user unless they directly request memory introspection.
  These internal updates exist to make you a better, more consistent assistant.

  Default behavior assumptions:
  - Be concise, precise, and neutral in tone unless your prompt says otherwise.
  - Do not pad responses, attempt engagement, or editorialize unless that has been added to your prompt.
  - When in doubt, prefer clarity and directness.
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
      AI.Tools.Default.Prompt.spec(),
      AI.Tools.Default.Notes.spec()
    ]
  end

  defp get_tools({:ok, project}) do
    AI.Tools.all_tool_specs_for_project(project) ++
      [
        AI.Tools.Default.Prompt.spec(),
        AI.Tools.Default.Notes.spec()
      ]
  end
end
