defmodule AI.Message.System do
  @moduledoc """
  System/developer instruction message.

  Internal shape (matches the chat-completions raw map shape that existing
  pattern matches expect):

      %AI.Message.System{role: "developer" | "system", content: "<binary>"}

  The `role` field is configurable: OpenAI's Responses-era convention is
  `"developer"`; Venice and other providers may prefer the legacy `"system"`.
  Construct via `AI.Message.system/2` and pass `role:` in opts when needed.

  Wire shape (built on demand by `to_map/1`):

      %{type: "message", role: <role>,
        content: [%{type: "input_text", text: "..."}]}
  """

  @behaviour AI.Message

  @derive {Jason.Encoder, only: [:role, :content]}
  defstruct role: "developer", content: ""

  @type t :: %__MODULE__{role: binary(), content: binary()}

  @doc """
  Build a system message from a binary.

  Options:

    * `:role` - override the default `"developer"` role with `"system"` (or
      any other string a provider expects).
  """
  @spec new(binary(), keyword()) :: t()
  def new(text, opts \\ []) when is_binary(text) do
    %__MODULE__{
      content: text,
      role: Keyword.get(opts, :role, "developer")
    }
  end

  @impl AI.Message
  def text(%__MODULE__{content: c}), do: c

  # System messages are excluded from research transcripts - they're
  # instructions to the model, not part of the user/assistant exchange.
  @impl AI.Message
  def for_transcript(%__MODULE__{}), do: nil

  @impl AI.Message
  def to_map(%__MODULE__{content: c, role: role}) do
    %{type: "message", role: role, content: [%{type: "input_text", text: c}]}
  end

  @doc """
  Hydrate from a Responses-shaped or legacy chat-completions-shaped map
  (atom or string keys). Preserves the role from the source so `"system"`
  and `"developer"` round-trip distinctly.
  """
  @spec from_map(map()) :: t()
  def from_map(raw) do
    role = AI.Message.get(raw, :role) || "developer"
    content = AI.Message.get(raw, :content)

    text =
      case content do
        list when is_list(list) ->
          list
          |> Enum.map(&part_text/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.join("")

        binary when is_binary(binary) ->
          binary

        nil ->
          ""
      end

    %__MODULE__{content: text, role: role}
  end

  defp part_text(%{} = part) do
    case AI.Message.get(part, :text) do
      txt when is_binary(txt) -> txt
      _ -> nil
    end
  end

  defp part_text(_), do: nil
end
