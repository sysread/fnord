defmodule AI.Message.User do
  @moduledoc """
  User input message. Wire shape:

      %{type: "message", role: "user",
        content: [%{type: "input_text", text: "..."}]}
  """

  @behaviour AI.Message

  @enforce_keys [:content]
  defstruct [:content]

  @type content_part :: %{type: binary(), text: binary()}
  @type t :: %__MODULE__{content: [content_part()]}

  @doc """
  Build a user message from a binary or pre-built content-parts list. A plain
  binary is wrapped as a single `input_text` part.
  """
  @spec new(binary() | [content_part()]) :: t()
  def new(text) when is_binary(text) do
    %__MODULE__{content: [%{type: "input_text", text: text}]}
  end

  def new(content) when is_list(content) do
    %__MODULE__{content: content}
  end

  @impl AI.Message
  def text(%__MODULE__{content: parts}) do
    parts
    |> Enum.map(&part_text/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  @impl AI.Message
  def for_transcript(%__MODULE__{} = msg), do: "# USER:\n#{text(msg)}"

  @impl AI.Message
  def to_map(%__MODULE__{content: parts}) do
    %{type: "message", role: "user", content: parts}
  end

  @doc """
  Hydrate from a Responses-shaped map (atom or string keys). Tolerates a
  legacy chat-completions shape (`%{role: "user", content: "binary"}`) so v0
  conversation files migrate cleanly.
  """
  @spec from_map(map()) :: t()
  def from_map(raw) do
    content = AI.Message.get(raw, :content)

    parts =
      case content do
        list when is_list(list) -> Enum.map(list, &normalize_part/1)
        text when is_binary(text) -> [%{type: "input_text", text: text}]
        nil -> []
      end

    %__MODULE__{content: parts}
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
