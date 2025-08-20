defmodule AI.Accumulator do
  @backoff_threshold 0.6
  @backoff_step 0.2

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
    :splitter,
    :buffer,
    :model,
    :toolbox,
    :prompt,
    :question,
    :completion_args,
    :line_numbers
  ]

  @type t :: %__MODULE__{
          splitter: AI.Splitter.t(),
          buffer: binary,
          model: binary,
          toolbox: AI.Tools.toolbox() | nil,
          prompt: binary,
          question: binary,
          completion_args: Keyword.t()
        }

  @line_numbers_prompt """
  The input you are processing includes line numbers.
  Each line is prefixed by a line number, separated by a pipe character (|).
  """

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
  4. Consistent Format: Append new content under "Accumulated Response"

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
  @type error :: {:error, binary}
  @type response :: success | error

  @spec get_response(Keyword.t()) :: response
  def get_response(opts \\ []) do
    with {:ok, model} <- Keyword.fetch(opts, :model),
         {:ok, prompt} <- Keyword.fetch(opts, :prompt),
         {:ok, input} <- Keyword.fetch(opts, :input),
         {:ok, question} <- Keyword.fetch(opts, :question) do
      line_numbers = Keyword.get(opts, :line_numbers, false)

      input =
        if line_numbers do
          Util.numbered_lines(input)
        else
          input
        end

      toolbox =
        opts
        |> Keyword.get(:toolbox, nil)
        |> AI.Tools.build_toolbox()

      %__MODULE__{
        splitter: AI.Splitter.new(input, model),
        buffer: "",
        model: model,
        toolbox: toolbox,
        prompt: prompt,
        question: question,
        completion_args: Keyword.get(opts, :completion_args, [])
      }
      |> reduce()
    else
      :error -> {:error, :missing_required_option}
    end
  end

  defp reduce(%{splitter: %{done: true}} = acc) do
    system_prompt = """
    #{@final_prompt}
    #{if acc.line_numbers, do: @line_numbers_prompt, else: ""}
    #{acc.prompt}
    """

    user_prompt = """
    # Question / Goal
    #{acc.question}

    # Accumulated Response
    #{acc.buffer}
    """

    args =
      acc.completion_args
      |> Keyword.put(:model, acc.model)
      |> Keyword.put(:toolbox, acc.toolbox)
      |> Keyword.put(:messages, [
        AI.Util.system_msg(system_prompt),
        AI.Util.user_msg(user_prompt)
      ])

    AI.Completion.get(args)
  end

  defp reduce(%{splitter: %{done: false}} = acc) do
    with {:ok, acc} <- process_chunk(acc) do
      reduce(acc)
    end
  end

  def process_chunk(acc), do: process_chunk(acc, 1.0)

  # ----------------------------------------------------------------------------
  # Processes a chunk of input by generating an updated accumulator response.
  #
  # The `frac` parameter represents the fraction of the model context to use
  # for this chunk. On context length exceeded errors, it backs off by subtracting
  # @backoff_step from frac, and retries. If frac drops below @backoff_threshold,
  # returns an error indicating unable to back off further.
  # ----------------------------------------------------------------------------
  defp process_chunk(_acc, frac) when frac < @backoff_threshold do
    {:error, "context window length exceeded: unable to back off further to fit the input"}
  end

  defp process_chunk(acc, frac) do
    max_chunk_tokens = round(acc.model.context * frac)

    # Build the "user message" prompt, which contains the accumulated response.
    user_prompt = """
    # Question / Goal
    #{acc.question}

    # Accumulated Response
    #{acc.buffer}
    """

    # Get the next chunk from the splitter and update the splitter state.
    # The next chunk size is limited by the remaining context tokens.
    {chunk, splitter} = AI.Splitter.next_chunk(acc.splitter, user_prompt, max_chunk_tokens)
    acc = %{acc | splitter: splitter}

    user_prompt = """
    #{user_prompt}
    -----
    #{chunk}
    """

    # Build the system prompt with the accumulator instructions and any relevant line number info.
    system_prompt = """
    #{@accumulator_prompt}
    #{if acc.line_numbers, do: @line_numbers_prompt, else: ""}
    #{acc.prompt}
    """

    args =
      acc.completion_args
      |> Keyword.put(:model, acc.model)
      |> Keyword.put(:toolbox, acc.toolbox)
      |> Keyword.put(:messages, [
        AI.Util.system_msg(system_prompt),
        AI.Util.user_msg(user_prompt)
      ])

    # Call AI.Completion.get and handle responses centrally
    args
    |> AI.Completion.get()
    |> case do
      {:ok, %{response: response}} ->
        {:ok, %{acc | splitter: splitter, buffer: response}}

      {:error, :context_length_exceeded} ->
        # Context length exceeded error handling:
        # Back off and retry with smaller fraction only if frac >= @backoff_threshold
        # If frac < @backoff_threshold, do not retry further and return error.
        if frac >= @backoff_threshold do
          UI.warn("Context length exceeded, backing off to fraction #{frac - @backoff_step}")
          process_chunk(acc, frac - @backoff_step)
        else
          UI.error("Context length exceeded, unable to back off further. THIS. IS. SPARTA!")
          {:error, "context window length exceeded: unable to back off further to fit the input"}
        end

      {:error, :api_unavailable} ->
        {:error, "API temporarily unavailable"}

      {:error, %AI.Completion{response: resp}} when is_binary(resp) ->
        {:error, resp}
    end
  end
end
