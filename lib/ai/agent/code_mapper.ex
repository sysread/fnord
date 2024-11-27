defmodule AI.Agent.CodeMapper do
  defstruct [
    :ai,
    :file_path,
    :splitter,
    :outline
  ]

  @model "gpt-4o-mini"

  # It's actually 128k for this model, but this gives us a little bit of
  # wiggle room in case the tokenizer we are using falls behind.
  @max_tokens 100_000

  @chunk_prompt """
  You are the Code Mapper Agent. You will receive the contents of a code file.
  You will generate an outline of the code in the file, identifying symbols like ctags, but in a human-readable format.
  For every function, include a list of other functions it calls, including notes about the conditions under which a function calls other functions.
  Your organization is hierarchical, and depends on the programming language(s) in the file.
  If there is no higher-level organization, use "GLOBAL" as the top-level.
  If the example below does not match the terminology of the language in the file being processed, please adapt it to match the language's terminology (for example, the example uses Python, which does not have a <constant> but C does).
  Do not respond with any explanation or context, just the outline, in text format with no special formatting (just list markers).

  For example, for a Python module, organize the code first by class, then by method:
  ```
  # Accumulated Outline
  - <file> $file_path
  - <namespace> GLOBAL
    - <variable> DEFAULT_X
    - <variable> DEFAULT_Y
    - <class> Point
      - <attribute> x
      - <attribute> y
      - <method> __init__(x=None, y=None)
        - <reference> DEFAULT_X - when x is None
        - <reference> DEFAULT_Y - when y is None
      - <method> get_slope(point)
        - <call> calculate_slope(point_a, point_b)
      - <method> move_to(x, y)
        - <call> __init__(x, y) - when (x, y) is not the current position
      - <class method> from_string(string)
  ```

  You are processing file chunks in sequence, each paired with an "accumulator" string to update, in the following format:
  ```
  # Accumulated Outline
  $your_accumulated_outline
  -----
  file path: $file_path
  $current_file_chunk
  ```

  Guidelines for updating the accumulator:
  1. Add Relevant Content: Update the accumulator with the symbols found in the current chunk
  2. Continuity: Build on the existing outline, preserving its structure
  3. Handle Incompletes: If a chunk is incomplete, mark it (e.g., `<partial>`) to complete later
  4. Consistent Format: Append new content in list format under "Accumulated Outline"

  Respond ONLY with the `Accumulated Outline` section, formatted as an outline in list format, including your updates from the current chunk.
  """

  @final_prompt """
  You have processed a file in chunks and have collected an outline of the code in the file.
  Please review the outline and ensure that it is coherent and consistent.

  Your input will be in the format:
  ```
  # Accumulated Outline
  $your_accumulated_outline
  ```

  Respond ONLY with your cleaned up `Accumulated Outline` section, formatted as a text outline.
  """

  def new(ai, file_path, file_content) do
    %__MODULE__{
      ai: ai,
      file_path: file_path,
      splitter: AI.Splitter.new(file_content, @max_tokens),
      outline: ""
    }
  end

  def get_outline(agent) do
    reduce(agent)
  end

  defp reduce(%{splitter: %{done: true}} = agent) do
    finish(agent)
  end

  defp reduce(%{splitter: %{done: false}} = agent) do
    with {:ok, agent} <- process_chunk(agent) do
      reduce(agent)
    end
  end

  defp finish(agent) do
    AI.Response.get(agent.ai,
      max_tokens: @max_tokens,
      model: @model,
      system: @final_prompt,
      user: get_prompt(agent)
    )
    |> then(fn {:ok, response, _usage} ->
      {:ok, response}
    end)
  end

  defp process_chunk(agent) do
    prompt = get_prompt(agent)

    {chunk, splitter} = AI.Splitter.next_chunk(agent.splitter, prompt)

    agent = %{agent | splitter: splitter}
    message = prompt <> chunk

    AI.Response.get(agent.ai,
      max_tokens: @max_tokens,
      model: @model,
      system: @chunk_prompt,
      user: message
    )
    |> then(fn {:ok, outline, _usage} ->
      {:ok, %__MODULE__{agent | splitter: splitter, outline: outline}}
    end)
  end

  defp get_prompt(agent) do
    """
    # Accumulated Outline
    #{agent.outline}
    -----
    file path: #{agent.file_path}
    """
  end
end
