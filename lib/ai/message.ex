defmodule AI.Message do
  @moduledoc """
  Canonical in-memory representation of conversation messages, modeled after
  the Responses API item shape.

  Each message is a struct from one of the impl modules below. Pattern-matching
  on `%mod{}` dispatches the behaviour callbacks (`text/1`, `for_transcript/1`,
  `to_map/1`). Construction goes through the short helpers at this module's
  top level (e.g. `AI.Message.user/1`); persistence and wire serialization go
  through `to_map/1`; hydration from disk or API response goes through
  `from_map/1`.

  ## Impls

    * `AI.Message.User` - user input message
    * `AI.Message.Assistant` - assistant reply message
    * `AI.Message.System` - system/developer instruction
    * `AI.Message.FunctionCall` - assistant-emitted tool call request
    * `AI.Message.FunctionCallOutput` - tool execution result
    * `AI.Message.Reasoning` - opaque reasoning item (round-tripped verbatim)

  ## Invariants

    * `FunctionCall.arguments` is ALWAYS a JSON string. Never decode it to a
      map for persistence - LLM-emitted garbage keys exhaust the BEAM atom
      table downstream. This is the cliff the previous Responses API attempt
      drove over; see the "Conversation file corruption" engram memory.
    * Content for User/Assistant/System is stored as a list of typed parts
      matching the wire format (`%{type: "input_text" | "output_text", text:
      ...}`). The `text/1` callback joins the parts back to a single binary.
  """

  @type t ::
          AI.Message.User.t()
          | AI.Message.Assistant.t()
          | AI.Message.System.t()
          | AI.Message.FunctionCall.t()
          | AI.Message.FunctionCallOutput.t()
          | AI.Message.Reasoning.t()

  # --------------------------------------------------------------------------
  # Behaviour callbacks
  # --------------------------------------------------------------------------

  @doc """
  Returns the plain-text representation of a message, or `nil` if the message
  has no textual content (e.g. a tool-call request or opaque reasoning blob).
  Joins multi-part content lists with newlines.
  """
  @callback text(t()) :: binary() | nil

  @doc """
  Returns a transcript-formatted block (with role headers, tool-call summary,
  etc.) suitable for inclusion in `AI.Util.research_transcript/1`-style
  outputs. `nil` if the message is omitted from transcripts.
  """
  @callback for_transcript(t()) :: binary() | nil

  @doc """
  Serializes a message struct to its on-the-wire (Responses API native) map
  shape. The result is what gets persisted to disk and sent to the API.
  """
  @callback to_map(t()) :: map()

  # --------------------------------------------------------------------------
  # Dispatching helpers
  # --------------------------------------------------------------------------

  @spec text(t()) :: binary() | nil
  def text(%mod{} = msg), do: mod.text(msg)

  @spec for_transcript(t()) :: binary() | nil
  def for_transcript(%mod{} = msg), do: mod.for_transcript(msg)

  @spec to_map(t()) :: map()
  def to_map(%mod{} = msg), do: mod.to_map(msg)

  # --------------------------------------------------------------------------
  # Constructors (terse aliases for the impl modules' new/1)
  # --------------------------------------------------------------------------

  @doc "Build an `AI.Message.User` from a binary or pre-built content list."
  @spec user(binary() | [map()]) :: AI.Message.User.t()
  def user(content), do: AI.Message.User.new(content)

  @doc "Build an `AI.Message.Assistant` from a binary or pre-built content list."
  @spec assistant(binary() | [map()]) :: AI.Message.Assistant.t()
  def assistant(content), do: AI.Message.Assistant.new(content)

  @doc """
  Build an `AI.Message.System`. Role defaults to `"developer"` (OpenAI's
  Responses-era convention); pass `role: "system"` for providers that prefer
  the legacy label.
  """
  @spec system(binary() | [map()], keyword()) :: AI.Message.System.t()
  def system(content, opts \\ []), do: AI.Message.System.new(content, opts)

  @doc """
  Build an `AI.Message.FunctionCall`. `arguments` MUST be a JSON-encoded string
  (the same form the API returns). Never pass a decoded map - see the module
  doc.
  """
  @spec function_call(binary(), binary(), binary()) :: AI.Message.FunctionCall.t()
  def function_call(call_id, name, arguments) when is_binary(arguments) do
    AI.Message.FunctionCall.new(call_id, name, arguments)
  end

  @doc "Build an `AI.Message.FunctionCallOutput` from a tool's textual result."
  @spec function_call_output(binary(), binary()) :: AI.Message.FunctionCallOutput.t()
  def function_call_output(call_id, output) do
    AI.Message.FunctionCallOutput.new(call_id, output)
  end

  @doc """
  Build an `AI.Message.Reasoning` from the raw reasoning item map returned by
  the API. The struct round-trips the raw shape so reasoning continuity is
  preserved when `store: false`.
  """
  @spec reasoning(map()) :: AI.Message.Reasoning.t()
  def reasoning(raw), do: AI.Message.Reasoning.new(raw)

  # --------------------------------------------------------------------------
  # Hydration from disk or API response
  # --------------------------------------------------------------------------

  @doc """
  Hydrate a struct from a Responses-API-shaped map. Accepts either atom-keyed
  or string-keyed maps - on-disk persistence uses string keys; in-memory
  construction uses atoms.

  Dispatches on `type` (and `role` for `"message"` items). Unknown shapes
  return `{:error, {:unknown_message_shape, raw}}`.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, {:unknown_message_shape, map()}}
  def from_map(raw) when is_map(raw) do
    case {get(raw, :type), get(raw, :role)} do
      {"message", "user"} -> {:ok, AI.Message.User.from_map(raw)}
      {"message", "assistant"} -> {:ok, AI.Message.Assistant.from_map(raw)}
      {"message", "system"} -> {:ok, AI.Message.System.from_map(raw)}
      {"message", "developer"} -> {:ok, AI.Message.System.from_map(raw)}
      {"function_call", _} -> {:ok, AI.Message.FunctionCall.from_map(raw)}
      {"function_call_output", _} -> {:ok, AI.Message.FunctionCallOutput.from_map(raw)}
      {"reasoning", _} -> {:ok, AI.Message.Reasoning.from_map(raw)}
      _ -> {:error, {:unknown_message_shape, raw}}
    end
  end

  @doc """
  Same as `from_map/1` but raises on unknown shapes. Use when persistence
  guarantees the shape (e.g. immediately after a successful Format migration).
  """
  @spec from_map!(map()) :: t()
  def from_map!(raw) do
    case from_map(raw) do
      {:ok, msg} -> msg
      {:error, reason} -> raise ArgumentError, "from_map!: #{inspect(reason)}"
    end
  end

  # Read a value from a map that may use either atom or string keys. We do
  # NOT call `String.to_atom/1` on raw map keys - that's the atom-table
  # cliff. Instead we look up both representations explicitly.
  @doc false
  def get(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
