defmodule AI.Tokenizer do
  @callback encode(String.t()) :: list()
  @callback decode(list()) :: String.t()

  @behaviour AI.Tokenizer

  @impl AI.Tokenizer
  def encode(text), do: AI.Tokens.encode(text)

  @impl AI.Tokenizer
  def decode(tokens), do: AI.Tokens.decode(tokens)
end
