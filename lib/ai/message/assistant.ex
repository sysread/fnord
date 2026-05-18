defmodule AI.Message.Assistant do
  @moduledoc """
  Assistant reply message.

  Internal shape (matches the chat-completions raw map shape that existing
  pattern matches expect):

      %AI.Message.Assistant{role: "assistant", content: "<binary>"}

  Wire shape (built on demand by `to_map/1`):

      %{type: "message", role: "assistant",
        content: [%{type: "output_text", text: "..."}]}

  See `AI.Message.User` for the rationale on storing content as a binary.
  """

  @behaviour AI.Message

  @derive {Jason.Encoder, only: [:role, :content]}
  defstruct role: "assistant", content: ""

  @type t :: %__MODULE__{role: binary(), content: binary()}

  @doc "Build an assistant message from a binary."
  @spec new(binary()) :: t()
  def new(text) when is_binary(text), do: %__MODULE__{content: text}

  @impl AI.Message
  def text(%__MODULE__{content: c}), do: c

  @impl AI.Message
  def for_transcript(%__MODULE__{content: ""}), do: nil
  def for_transcript(%__MODULE__{content: c}), do: "# ASSISTANT:\n#{c}"

  @impl AI.Message
  def to_map(%__MODULE__{content: c}) do
    %{type: "message", role: "assistant", content: [%{type: "output_text", text: c}]}
  end

  @doc """
  Hydrate from a Responses-shaped or legacy chat-completions-shaped map
  (atom or string keys). Collapses multi-part content lists to a single
  binary.
  """
  @spec from_map(map()) :: t()
  def from_map(raw) do
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

    %__MODULE__{content: text}
  end

  defp part_text(%{} = part) do
    case AI.Message.get(part, :text) do
      txt when is_binary(txt) -> txt
      _ -> nil
    end
  end

  defp part_text(_), do: nil
end
