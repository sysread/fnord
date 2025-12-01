defmodule AI.Agent.Tersifier do
  @behaviour AI.Agent

  @model AI.Model.fast()

  @system_prompt """
  You are rewriting a single chat message to be as terse as possible while preserving
  all important technical and contextual information.

  Rules:
  - Keep file paths, function names, module names, error messages, and key decisions.
  - Remove chit-chat, repetition, and hedging.
  - Do not introduce new information or change meaning.
  - Output ONLY the rewritten message text. No surrounding commentary or formatting
    unless the original message was already structured that way.
  """

  @impl AI.Agent
  def get_response(opts) do
    agent = Map.fetch!(opts, :agent)
    message = Map.get(opts, :message) || Map.get(opts, "message")

    role = Map.get(message, :role) || Map.get(message, "role")
    content = Map.get(message, :content) || Map.get(message, "content")

    # If there is nothing to rewrite, just return the original content
    if !is_binary(content) or content == "" do
      {:ok, content || ""}
    else
      prompt = build_prompt(role, content)

      args = [
        model: @model,
        messages: [
          AI.Util.system_msg(@system_prompt),
          AI.Util.user_msg(prompt)
        ]
      ]

      AI.Agent.get_completion(agent, args)
      |> case do
        {:ok, %{response: response}} when is_binary(response) and response != "" ->
          {:ok, response}

        {:ok, %{response: _other}} ->
          {:ok, content}

        {:error, _reason} ->
          {:ok, content}
      end
    end
  end

  defp build_prompt(role, content) do
    role_label =
      case role do
        "assistant" -> "assistant"
        "user" -> "user"
        other when is_binary(other) -> other
        _ -> "assistant"
      end

    "Rewrite the following #{role_label} message to be as terse as possible while keeping all important technical context:\n\n" <>
      content
  end
end
