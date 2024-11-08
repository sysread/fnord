defmodule AI.Tokenizer do
  @callback encode(String.t()) :: list()
  @callback decode(list()) :: String.t()

  @behaviour AI.Tokenizer

  @impl AI.Tokenizer
  def encode(text), do: Gpt3Tokenizer.encode(text)

  @impl AI.Tokenizer
  def decode(tokens), do: Gpt3Tokenizer.decode(tokens)
end
