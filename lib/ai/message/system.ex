defmodule AI.Message.System do
  @moduledoc """
  System/developer instruction message. Wire shape:

      %{type: "message", role: "developer",
        content: [%{type: "input_text", text: "..."}]}

  The `role` field is configurable: OpenAI's Responses-era convention is
  `"developer"`; Venice and other providers may prefer the legacy `"system"`.
  Construct via `AI.Message.system/2` and pass `role:` in opts when needed.
  """

  @behaviour AI.Message

  @enforce_keys [:content]
  defstruct content: [], role: "developer"

  @type content_part :: %{type: binary(), text: binary()}
  @type t :: %__MODULE__{content: [content_part()], role: binary()}

  @doc """
  Build a system message from a binary or pre-built content-parts list.

  Options:

    * `:role` - override the default `"developer"` role with `"system"` (or
      any other string a provider expects).
  """
  @spec new(binary() | [content_part()], keyword()) :: t()
  def new(text_or_parts, opts \\ [])

  def new(text, opts) when is_binary(text) do
    %__MODULE__{
      content: [%{type: "input_text", text: text}],
      role: Keyword.get(opts, :role, "developer")
    }
  end

  def new(content, opts) when is_list(content) do
    %__MODULE__{
      content: content,
      role: Keyword.get(opts, :role, "developer")
    }
  end

  @impl AI.Message
  def text(%__MODULE__{content: parts}) do
    parts
    |> Enum.map(&part_text/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  # System messages are excluded from research transcripts - they're
  # instructions to the model, not part of the user/assistant exchange.
  @impl AI.Message
  def for_transcript(%__MODULE__{}), do: nil

  @impl AI.Message
  def to_map(%__MODULE__{content: parts, role: role}) do
    %{type: "message", role: role, content: parts}
  end

  @doc """
  Hydrate from a Responses-shaped map (atom or string keys). Preserves the
  role from the source so `"system"` and `"developer"` round-trip distinctly.
  Tolerates a legacy chat-completions shape with a binary `content`.
  """
  @spec from_map(map()) :: t()
  def from_map(raw) do
    role = AI.Message.get(raw, :role) || "developer"
    content = AI.Message.get(raw, :content)

    parts =
      case content do
        list when is_list(list) -> Enum.map(list, &normalize_part/1)
        text when is_binary(text) -> [%{type: "input_text", text: text}]
        nil -> []
      end

    %__MODULE__{content: parts, role: role}
  end

  defp normalize_part(%{} = part) do
    type = AI.Message.get(part, :type) || "input_text"
    text = AI.Message.get(part, :text) || ""
    %{type: type, text: text}
  end

  defp part_text(%{type: _, text: text}) when is_binary(text), do: text
  defp part_text(%{"type" => _, "text" => text}) when is_binary(text), do: text
  defp part_text(_), do: nil
end
