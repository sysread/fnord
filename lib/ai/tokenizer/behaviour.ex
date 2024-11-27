defmodule AI.Tokenizer.Behaviour do
  @callback decode(list()) :: String.t()
  @callback encode(String.t()) :: list()
end
