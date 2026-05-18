defmodule AI.Message.FunctionCall do
  @moduledoc """
  Assistant-emitted tool call request. Wire shape:

      %{type: "function_call", call_id: "...", name: "tool_name",
        arguments: "<json-encoded-string>"}

  ## Critical invariant

  `arguments` MUST be a JSON-encoded **string**, NEVER a decoded map. The
  previous Responses API attempt drove off this cliff: when arguments are
  stored as maps, `Util.string_keys_to_atoms/1` recurses into them on read
  and atomizes LLM-emitted garbage keys, exhausting the BEAM atom table.
  See engram memory "Conversation file corruption - responses branch tool
  arguments".

  Callers that need to parse the arguments map can do so on demand at the
  call site (where the keys are bounded by the tool's schema), but the
  canonical form on disk and in memory is the raw JSON string.
  """

  @behaviour AI.Message

  @derive {Jason.Encoder, only: [:type, :call_id, :name, :arguments]}
  @enforce_keys [:call_id, :name, :arguments]
  defstruct [:call_id, :name, :arguments, type: "function_call"]

  @type t :: %__MODULE__{
          call_id: binary(),
          name: binary(),
          arguments: binary()
        }

  @doc """
  Build a function-call request. `arguments` must already be a JSON string.
  """
  @spec new(binary(), binary(), binary()) :: t()
  def new(call_id, name, arguments)
      when is_binary(call_id) and is_binary(name) and is_binary(arguments) do
    %__MODULE__{call_id: call_id, name: name, arguments: arguments}
  end

  # FunctionCall items have no textual content of their own; transcript
  # rendering happens at the call site where the corresponding output is also
  # available.
  @impl AI.Message
  def text(%__MODULE__{}), do: nil

  @impl AI.Message
  def for_transcript(%__MODULE__{name: name, arguments: args}) do
    """
    # TOOL CALL: #{name}
    Arguments: #{args}
    """
  end

  @impl AI.Message
  def to_map(%__MODULE__{call_id: call_id, name: name, arguments: arguments}) do
    %{type: "function_call", call_id: call_id, name: name, arguments: arguments}
  end

  @doc """
  Hydrate from a Responses-shaped map (atom or string keys). Re-encodes
  `arguments` to a JSON string if a legacy v0 conversation file stored it as
  a decoded map - the atom-table-safe invariant on disk is "string", not
  "map".
  """
  @spec from_map(map()) :: t()
  def from_map(raw) do
    call_id = AI.Message.get(raw, :call_id) || AI.Message.get(raw, :id) || ""
    name = AI.Message.get(raw, :name) || ""
    arguments = normalize_arguments(AI.Message.get(raw, :arguments))

    %__MODULE__{call_id: call_id, name: name, arguments: arguments}
  end

  defp normalize_arguments(args) when is_binary(args), do: args

  defp normalize_arguments(args) when is_map(args) do
    # Defensive re-encode for older shapes that decoded the JSON. SafeJson is
    # the project's wrapper around Jason; this never raises because we always
    # have a real map here.
    case SafeJson.encode(args) do
      {:ok, json} -> json
      {:error, _} -> "{}"
    end
  end

  defp normalize_arguments(nil), do: "{}"
end
