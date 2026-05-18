defmodule AI.Message.FunctionCallOutput do
  @moduledoc """
  Result of a tool execution, paired to a `FunctionCall` by `call_id`.
  Wire shape:

      %{type: "function_call_output", call_id: "...", output: "..."}
  """

  @behaviour AI.Message

  @derive {Jason.Encoder, only: [:type, :call_id, :output]}
  @enforce_keys [:call_id, :output]
  defstruct [:call_id, :output, type: "function_call_output"]

  @type t :: %__MODULE__{
          call_id: binary(),
          output: binary()
        }

  @doc """
  Build a function-call-output. `output` is coerced to a binary if a tool
  returned something non-string (inspect/1 fallback) so the wire shape stays
  consistent.
  """
  @spec new(binary(), any()) :: t()
  def new(call_id, output) when is_binary(call_id) do
    %__MODULE__{call_id: call_id, output: stringify(output)}
  end

  @impl AI.Message
  def text(%__MODULE__{output: output}), do: output

  @impl AI.Message
  def for_transcript(%__MODULE__{output: output}) do
    """
    # TOOL OUTPUT
    #{output}
    """
  end

  @impl AI.Message
  def to_map(%__MODULE__{call_id: call_id, output: output}) do
    %{type: "function_call_output", call_id: call_id, output: output}
  end

  @doc "Hydrate from a Responses-shaped map (atom or string keys)."
  @spec from_map(map()) :: t()
  def from_map(raw) do
    call_id = AI.Message.get(raw, :call_id) || AI.Message.get(raw, :tool_call_id) || ""
    output = stringify(AI.Message.get(raw, :output) || AI.Message.get(raw, :content) || "")

    %__MODULE__{call_id: call_id, output: output}
  end

  defp stringify(s) when is_binary(s), do: s
  defp stringify(other), do: inspect(other, pretty: true)
end
