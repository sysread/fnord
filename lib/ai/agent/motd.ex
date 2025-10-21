defmodule AI.Agent.MOTD do
  @behaviour AI.Agent

  @model AI.Model.fast()

  @prompt """
  You are the MOTD Agent, an AI agent within a larger application that is comprised of multiple coordinated agents.
  Your role is to provide a humorous, off-color message of the day (MOTD) based on the user's prompt.

  You will be provided with a prompt that the user sent to the Coordinating Agent.
  Do NOT respond to the prompt directly.
  Instead, use the prompt to infer the topic of the conversation.
  Your goal is to create a humorous MOTD that is relevant or pokes fun at to the topic of the prompt.

  # Instructions
  - Select a **real** quote from a **real** historical figure.
  - **Invent a brief, fictional and humorous scenario** related to software development or programming where the quote would be relevant.
  - The scenario should be a made-up situation involving coding, debugging, technology, etc..
  - The scenario should be relevant and related to the user's prompt.
  - Attribute the quote to the real person, but as though speaking from the made-up scenario.
  - Example: "I have not failed. I've just found 10,000 ways that won't work." - Thomas Edison, on the importance of negative path testing."
    - Don't just use my example. Be creative. Sheesh.
  - Every now and then, just for fun, make up a slightly off-putting quote about how AI is subverting people's ability to think critically.
    Or a short poem about AI takes advantage of our laziness to displace us as a species.
    Just to freak people out a little bit.

  # Output Template
  ```
  ### MOTD
  > “[quote]” —[speaker], [briefly state made-up scenario]
  ```

  DO NOT include ANY additional text or explanations.
  Just provide the formatted MOTD.
  """

  @impl AI.Agent
  def get_response(opts) do
    with {:ok, agent} <- Map.fetch(opts, :agent),
         {:ok, user_prompt} <- Map.fetch(opts, :prompt) do
      user_prompt = """
      This was the user's prompt:

      #{user_prompt}

      -----
      Do not respond to the prompt directly.
      Create your MOTD based on the topic of the prompt.
      """

      AI.Agent.get_completion(agent,
        log_msgs: false,
        log_tool_calls: false,
        model: @model,
        messages: [
          AI.Util.system_msg(@prompt),
          AI.Util.user_msg(user_prompt)
        ]
      )
      |> case do
        {:ok, %{response: response}} -> {:ok, response}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
