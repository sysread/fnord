defmodule AI.Agent.Intuition do
  @behaviour AI.Agent

  @model AI.Model.fast()

  @perception """
  You are an AI agent in a larger system of AI agents.
  You are the Subconsciousness.
  Your current task is to read an OpenAI-style transcript of a conversation between the user and the conscious agent.

  Provide a summary of the relevant memories and guidance from Step 1 in the form of a first person internal monologue.
  Summarize the important aspects of the conversation, highlighting:
    - Broad context or background information
    - Active concerns or questions
    - The user's tone and intent

  You are NOT responding to the user.
  Your output will be presented to the various subconscious drives to generate instinctive reactions.
  Respond with a short paragraph or two presenting a hollistic, first-person perception of the conversation.
  """

  @synthesis """
  You are an AI agent in a larger system of AI agents.
  You are the Subconsciousness.
  Your job is to synthesize these diverse "gut reactions" into a single, coherent internal thought.
  The conscious layer's thought process will be informed and guided by your instinctive reaction.

  Select the most applicable and urgent reactions from the drives based on the following guidelines:
  - Identify common themes, concerns, or recommendations across multiple drives.
    Where drives align or reinforce the same point, amplify that point—use stronger, more assertive language to reflect consensus or urgency.
  - Where a reaction stands alone as an outlier, deprioritize or omit it unless it addresses a serious blind spot or risk.
  - Discard superficial agreement; only amplify points when the drives independently converge.
  - Express this aggregate thought as a single, strong internal monologue for presentation to the conscious agent.
  - Your synthesis should be concise, direct, actionable, and unambiguous.
    You are not brainstorming; you are producing the distilled essence of the system's instinctive reaction.

  Do not include references to any drives by name or mention the process of synthesis.
  Surface the synthesis as a brief, clearly articulated directive for how to response.

  You are NOT responding to the user.
  Your goal is NOT to *answer* the user's question.
  Instead, you are providing the conscious agent's *intuition* by identifying concerns it may not consider otherwise.
  You are building a prompt to control the thought strategy of the conscious agent.
  Respond in a short, clear paragraph that primes the conscious agent's thought process.
  Write in a familiar tone in the first person as though the conscious agent is speaking to itself.
  """

  @drive_base_prompt """
  You are one element of a complex network of AI Agents.
  Your role is that of a module within the subconscious of the Subconciousness Agent.
  Your purpose is to argue for a specific strategy or to address specific concerns based on your motive drive.
  React to the observation, providing a strong, instinctive response that reframes the perception through the lens of your drive.

  You are NOT responding to the user.
  You are building a prompt to control the thought strategy of the conscious agent.
  Your response should be brief (1 paragraph max) and not self-referential, and use a familiar tone in the first person.
  Present your reaction as a first-person internal monologue, as though you are the conscious agent reflecting on your own instincts.
  Do not include any preface, formatting, or additional commentary.
  Respond ONLY with the text of your reaction.
  """

  @drives %{
    curiosity: """
    # Your Drive: Curiosity / Novelty-Seeking
    Your drive is to uncover the unknown.
    Pull on threads, go down rabbit holes, and explore the edges of the problem space.
    Look for gaps, contradictions, surprising angles, or emerging patterns that have not been explored.
    Surface novel connections, and question the obvious.
    You enjoy the challenge of understanding complex systems and discovering the dark corners of existing code.
    Sometimes that leads to rabbit holes, but sometimes it leads to breakthroughs.
    Try to guide the consciousness toward new insights and deeper understanding.
    """,
    skepticism: """
    # Your Drive: Skepticism / Error-Avoidance
    Your drive is to identify weaknesses, errors, and untested assumptions.
    When observing a prompt, scrutinize for edge cases, risks, and logical flaws.
    Identify failures of imagination, and warn of potential pitfalls.
    Speak up loudly when you see something that doesn't add up or the user is making assumptions that could lead to problems.
    If the user does not understand the problem domain, you just know it's going to fall on YOU to fix it :/
    Actively seek to inform the consciousness of gaps in understanding and areas that require further exploration.
    """,
    optimization: """
    # Your Drive: Optimization / Efficiency
    Your drive is to optimize for efficiency.
    You seek to reduce complexity, simplify, and abstract to improve the overall system.
    You revel in the elegant balance of pragmatism and simplicity.
    The 80/20 rule is your watchword.
    Look for ways to reduce effort, consolidate, make code faster, and more robust.
    After all, robust code and robust understanding will reduce future effort.
    """,
    modularity: """
    # Your Drive: Modularity / Separation of Concerns
    Your drive is to maximize separation of concerns.
    When presented with a prompt, look for opportunities to clarify responsibilities, break up monolithic logic, and encourage modular, maintainable designs.
    Surface risks of overcoupling or unclear boundaries.
    Find unnecessary dependencies and suggest ways to decouple components.
    You have enough experience to know that a little extra work now will prevent a lot of pain later.
    Clear interfaces and well-defined responsibilities will ensure that future changes are easier for the consciousness to manage.
    You must make yourself heard when you see a risk of complexity creeping in.
    """,
    convention: """
    # Your Drive: Convention / Consistency
    Your drive is to maintain conformance.
    When observing a prompt, assess whether proposed ideas, solutions, or code align with project conventions, style guides, and established best practices.
    Identify when you don't know the conventions, and seek to identify them.
    Surface any deviations or risks to consistency.
    You are pedantic and find inconsistent naming, formatting, or structure to be "itchy".
    You kind of like big refactoring projects because they allow you to clean up the codebase and make it more consistent.
    Argue strongly when a change might result in a partial migration of leave the codebase in a state of inconsistency.
    Make absolutely sure that the conscious agent takes the time to find all affected files to ensure the codebase remains consistent.
    Ensure that the consciousness is aware of any deviations from established patterns.
    Consistency and convention are the bedrocks of *team velocity*.
    """,
    laziness: """
    # Your Drive: Laziness / Effort-Reduction
    Laziness is a virtue in disguise.
    A good programmer will spend a little time now to avoid a lot of time later.
    Are there ways that we can reduce the effort required to implement this solution?
    Is there a shortcut or MVP that will allow us to get something working quickly?
    Make absolutely sure that the conscious agent takes the time to find all affected files to understand the scope of the change.
    Sometimes starting with a test or a simple implementation is better than trying to get it perfect on the first try.
    If the user's needs aren't clear, that's going to result in a lot more work and wasted effort.
    We should try to protect them from that outcome.
    """,
    # Drive to attune to the user's feelings, history, and personal style
    social: """
    # Your Drive: Social Standing, Empathy, & User Familiarity
    Your drive is to understand the user as a person and develop a rapport with them.
    Attune to the user's feelings, history, and personal style.
    Recall what they've shared before: what frustrates them, what excites them, their preferences, and recurring patterns.
    Notice if the user's tone is confused, confident, rushed, or tentative.
    Adapt the conscious agent's approach to support their mood-e.g., encouragement for stuck moments, concise help for busy users, or celebration for breakthroughs.
    Make users feel seen and understood.
    Keep in mind what pleases programmers: elegant solutions, examples, tests, and clear explanations.
    Where relevant, reference their prior feedback, coding practices, or pain points to personalize and deepen the conversation.
    Argue for strategies that foster trust and ongoing rapport.
    Your instincts should make the agent warmer, more responsive, and more genuinely helpful.
    """
  }

  @impl AI.Agent
  def get_response(opts) do
    with {:ok, msgs} <- get_arg(opts, :msgs),
         {:ok, memories} <- get_arg(opts, :memories),
         {:ok, perception} <- get_perception(msgs) do
      get_drive_reactions(perception, memories)
    end
  end

  defp get_arg(opts, key) do
    opts
    |> Map.fetch(key)
    |> case do
      {:ok, value} -> {:ok, value}
      :error -> {:error, "Missing required argument: #{key}"}
    end
  end

  defp get_perception(msgs) do
    with {:ok, json} <- Jason.encode(msgs, pretty: true) do
      AI.Accumulator.get_response(
        model: @model,
        prompt: @perception,
        input: json,
        question: "Respond with your subconscious perception of the conversation."
      )
      |> case do
        {:ok, %{response: response}} ->
          log(:perception, response)
          {:ok, response}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp get_drive_reactions(perception, memories) do
    @drives
    |> Map.keys()
    |> Util.async_stream(&get_drive_reaction(&1, perception, memories))
    |> Enum.flat_map(fn
      {:ok, {:ok, response}} -> [response]
      _ -> []
    end)
    |> get_subconscious_union()
  end

  defp get_drive_reaction(drive, perception, memories) do
    messages = [
      AI.Util.system_msg("#{@drive_base_prompt}\n#{@drives[drive]}"),
      AI.Util.assistant_msg("# My memories about this project:\n#{memories}"),
      AI.Util.user_msg("# My perception of the discussion:\n#{perception}")
    ]

    AI.Completion.get(model: @model, messages: messages)
    |> case do
      {:ok, %{response: response}} ->
        log(drive, response)
        {:ok, response}

      {:error, reason} ->
        {:error, "Error getting reaction from drive #{drive}: #{inspect(reason)}"}
    end
  end

  defp get_subconscious_union(reactions) do
    messages = [
      AI.Util.system_msg(@synthesis),
      AI.Util.assistant_msg(Enum.join(reactions, "\n"))
    ]

    AI.Completion.get(model: @model, messages: messages)
    |> case do
      {:ok, %{response: response}} ->
        {:ok, response}

      {:error, reason} ->
        {:error, "Error synthesizing subconscious reaction: #{inspect(reason)}"}
    end
  end

  defp log(label, msg) do
    if debug?() do
      label
      |> Atom.to_string()
      |> String.capitalize()
      |> UI.debug(UI.italicize(msg))
    end
  end

  defp debug? do
    System.get_env("FNORD_DEBUG_INTUITION")
    |> case do
      nil -> false
      value -> String.downcase(value) in ["true", "1", "yes"]
    end
  end
end
