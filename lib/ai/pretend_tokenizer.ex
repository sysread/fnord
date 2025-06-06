defmodule AI.PretendTokenizer do
  @moduledoc """
  OpenAI's tokenizer uses regexes that are not compatible with Erlang's regex
  engine. There are a couple of modules available on hex, but all of them
  require a working python installation, access to rustc, a number of external
  dependencies, and some env flags set to allow it to compile.

  Rather than impose that on end users, this module guesstimates token counts
  based on OpenAI's assertion that 1 token is approximately 4 characters.
  Callers must take that into account when selecting their chunk size,
  including some amount of buffer to account for the inaccuracy of this
  approximation.
  """
  @type input :: String.t()
  @type chunk_size :: non_neg_integer() | AI.Model.t()
  @type reduction_factor :: float()
  @type chunked_input :: [String.t()]

  @spec chunk(input, chunk_size, reduction_factor) :: chunked_input
  def chunk(input, %AI.Model{context: tokens}, reduction_factor) do
    chunk(input, tokens, reduction_factor)
  end

  def chunk(input, chunk_size, reduction_factor) do
    target = trunc(chunk_size * 4 * reduction_factor)
    size = target - rem(target, 4)

    input
    |> String.graphemes()
    |> Enum.chunk_every(size)
    |> Enum.map(&Enum.join/1)
  end

  def guesstimate_tokens(input) do
    (String.length(input) / 4)
    |> ceil()
  end

  def over_max_for_openai_embeddings?(input) do
    guesstimate_tokens(input) > 300_000
  end
end
