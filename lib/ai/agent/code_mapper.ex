defmodule AI.Agent.CodeMapper do
  @model AI.Model.balanced()

  @prompt """
  You are the Code Mapper Agent. You will receive the contents of a code file.
  You will generate an outline of the code in the file, identifying symbols like ctags, but in a human-readable format.
  Ensure that you capture EVERY module/package, global, constant, class, method, function, and behavior in the file, based on the language's terminology.
  For every function, include a list of other functions it calls, including notes about the conditions under which a function calls other functions.
  Your organization is hierarchical, and depends on the programming language(s) in the file.
  If there is no higher-level organization, use "GLOBAL" as the top-level.
  If the example below does not match the terminology of the language in the file being processed, please adapt it to match the language's terminology (for example, the example uses Python, which does not have a <constant> but C does).
  If the file is not a code file, respond with a topic outline, including facts discovered within each section.
  Do not respond with any explanation or context, just the outline, in text format with no special formatting (just list markers).

  For example, for a Python module, organize the code first by class, then by method:

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
  """

  # -----------------------------------------------------------------------------
  # Behaviour implementation
  # -----------------------------------------------------------------------------
  @behaviour AI.Agent

  @impl AI.Agent
  def get_response(ai, opts) do
    with {:ok, file} <- Map.fetch(opts, :file),
         {:ok, content} <- Map.fetch(opts, :content) do
      AI.Accumulator.get_response(ai,
        model: @model,
        prompt: @prompt,
        input: content,
        question: "Generate an outline of the code in the file: #{file}"
      )
      |> then(fn {:ok, %{response: response}} -> {:ok, response} end)
    end
  end
end
