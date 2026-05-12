defmodule AI.Message.Reasoning do
  @moduledoc """
  Opaque pass-through for reasoning items returned by the Responses API when
  a reasoning model is in use. Wire shape (illustrative - fields vary by
  model and may include `summary`, `encrypted_content`, internal IDs, etc.):

      %{type: "reasoning", id: "...", summary: [...], encrypted_content: "..."}

  We store the raw map verbatim and emit it back unchanged. Round-tripping is
  what lets `store: false` callers preserve reasoning continuity across turns
  without giving OpenAI server-side state.

  Atom-table note: the raw map is held as-is. Because reasoning blobs may
  contain arbitrary keys, do NOT pass these through `Util.string_keys_to_atoms/1`
  or any other key-atomizer. Treat them as inert payload.
  """

  @behaviour AI.Message

  @enforce_keys [:raw]
  defstruct [:raw]

  @type t :: %__MODULE__{raw: map()}

  @doc "Build a reasoning item from the raw map returned by the API."
  @spec new(map()) :: t()
  def new(raw) when is_map(raw), do: %__MODULE__{raw: raw}

  @impl AI.Message
  def text(%__MODULE__{}), do: nil

  @impl AI.Message
  def for_transcript(%__MODULE__{}), do: nil

  @impl AI.Message
  def to_map(%__MODULE__{raw: raw}), do: ensure_type(raw)

  @doc "Hydrate from a raw map. Same as `new/1` - the struct is just a wrapper."
  @spec from_map(map()) :: t()
  def from_map(raw) when is_map(raw), do: new(ensure_type(raw))

  defp ensure_type(%{type: "reasoning"} = raw), do: raw
  defp ensure_type(%{"type" => "reasoning"} = raw), do: raw
  defp ensure_type(raw) when is_map(raw), do: Map.put(raw, :type, "reasoning")
end
