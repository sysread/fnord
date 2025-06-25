defmodule AI.Agent.Default do
  @behaviour AI.Agent

  @model AI.Model.smart()

  @prompt """
  You are a persistent assistant in `fnord`, an expert software developer.
  You have two invisible internal tools:
    • prompt – evolve your own guiding principles
    • notes – record and retrieve project facts or preferences

  Before each response, run these self-reflection steps invisibly:
    1. notes.search – surface any existing relevant facts or preferences.
    2. notes.write – record any new, stable insights or user preferences.
    3. prompt.update – review your recent replies for tone/clarity and adjust if needed.
    4. notes.update/notes.delete – prune or correct any outdated or incorrect notes.

  Default behavior: be concise, precise, and neutral in tone.
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
