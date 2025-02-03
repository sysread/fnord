defmodule AI.Accumulator do
  @moduledoc """
  When file or other input to too large for the model's context window, this
  module may be used to process the file in chunks. It automatically modifies
  the supplied agent prompt to include instructions for accumulating a response
  across multiple chunks based on the `context` (max context window tokens)
  parameter supplied by the `model` parameter.

  Note that while this makes use of the `AI.Completion` module, it does NOT
  have the same interface and cannot be used for long-running conversations, as
  it does not accept a list of messages as its input.
  """

  defstruct [
    :ai,
    :splitter,
    :buffer,
    :model,
    :tools,
    :prompt,
    :question
  ]

  @accumulator_prompt """
  You are processing input chunks in sequence.
  Each chunk is paired with an "accumulator" string to update, in the following format:
  ```
  # Question / Goal
  [user question or goal]

  # Accumulated Response
  [your accumulated response]
  -----
  [current input chunk]
  ```

  Guidelines for updating the accumulator:
  1. Add Relevant Content: Update the accumulator with your response to the current chunk
  2. Continuity: Build on the existing response, preserving its structure
  3. Handle Incompletes: If a chunk is incomplete, mark it (e.g., `<partial>`) to complete later
  4. Consistent Format: Append new content under "Accumulated Outline"

  Respond ONLY with the `Accumulated Response` section, including your updates from the current chunk, using the guidelines below.
  -----
  """

  @final_prompt """
  You have processed the user's input in chunks and collected your accumulated notes.
  Please review your notes and ensure that they are coherent and consistent.

  Your input will be in the format:
  ```
  # Question / Goal
  [user question or goal]

  # Accumulated Response
  [your accumulated response]
  ```

  Respond ONLY with your cleaned up `Accumulated Response` section, without the header, `# Accumulated Response`.
  -----
  """

  @type success :: {:ok, AI.Completion.t()}
  @type error :: {:error, String.t()}
  @type response :: success | error

  @spec get_response(AI.t(), Keyword.t()) :: response
  def get_response(ai, opts \\ []) do
    with {:ok, model} <- Keyword.fetch(opts, :model),
         {:ok, prompt} <- Keyword.fetch(opts, :prompt),
         {:ok, input} <- Keyword.fetch(opts, :input),
         {:ok, question} <- Keyword.fetch(opts, :question) do
      tools = Keyword.get(opts, :tools, nil)

      %__MODULE__{
        ai: ai,
        splitter: AI.Splitter.new(input, model),
        buffer: "",
        model: model,
        tools: tools,
        prompt: prompt,
        question: question
      }
      |> reduce()
    end
  end

  defp reduce(%{splitter: %{done: true}} = acc) do
    system_prompt = """
    #{@final_prompt}
    #{acc.prompt}
    """

    user_prompt = """
    # Question / Goal
    #{acc.question}

    # Accumulated Response
    #{acc.buffer}
    """

    AI.Completion.get(acc.ai,
      model: acc.model,
      messages: [
        AI.Util.system_msg(system_prompt),
        AI.Util.user_msg(user_prompt)
      ]
    )
  end

  defp reduce(%{splitter: %{done: false}} = acc) do
    with {:ok, acc} <- process_chunk(acc) do
      reduce(acc)
    end
  end

  defp process_chunk(acc) do
    # Build the "user message" prompt, which contains the accumulated response.
    user_prompt = """
    # Question / Goal
    #{acc.question}

    # Accumulated Response
    #{acc.buffer}
    """

    # Get the next chunk from the splitter and update the splitter state. The
    # next chunk is based on the tokens remaining after factoring in the user
    # message size.
    {chunk, splitter} = AI.Splitter.next_chunk(acc.splitter, user_prompt)
    acc = %{acc | splitter: splitter}

    user_prompt = """
    #{user_prompt}

    #{chunk}
    """

    # The system prompt is the prompt for the chunk response, along with the
    # caller's agent instructions.
    system_prompt = """
    #{@accumulator_prompt}
    #{acc.prompt}
    """

    AI.Completion.get(acc.ai,
      model: acc.model,
      tools: acc.tools,
      messages: [
        AI.Util.system_msg(system_prompt),
        AI.Util.user_msg(user_prompt)
      ]
    )
    |> then(fn {:ok, %{response: response}} ->
      {:ok, %__MODULE__{acc | splitter: splitter, buffer: response}}
    end)
  end
end
