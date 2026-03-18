defmodule AI.PretendTokenizer do
  @moduledoc """
  OpenAI's tokenizer uses regexes that are not compatible with Erlang's regex
  engine. There are a couple of modules available on hex, but all of them
  require a working python installation, access to rustc, a number of external
  dependencies, and some env flags set to allow it to compile.

  Rather than impose that on end users, this module uses a deliberately
  conservative token estimator. It guesstimates token counts with extra room
  for token-dense inputs so callers can choose chunk sizes with a buffer for
  inaccuracy.
  """
  @type input :: String.t()
  @type chunk_size :: non_neg_integer() | AI.Model.t()
  @type reduction_factor :: float()
  @type chunked_input :: [String.t()]

  @chars_per_token 3

  @spec chunk(input, chunk_size, reduction_factor) :: chunked_input
  def chunk(input, %AI.Model{context: tokens}, reduction_factor) do
    chunk(input, tokens, reduction_factor)
  end

  def chunk(input, chunk_size, reduction_factor) do
    size = chunk_size(chunk_size, reduction_factor)

    input
    |> String.graphemes()
    |> Enum.chunk_every(size)
    |> Enum.map(&Enum.join/1)
  end

  def guesstimate_tokens(input) do
    (String.length(input) / @chars_per_token)
    |> ceil()
  end

  def over_max_for_openai_embeddings?(input) do
    guesstimate_tokens(input) > 300_000
  end

  defp chunk_size(token_target, reduction_factor) do
    target = trunc(token_target * @chars_per_token * reduction_factor)

    case target do
      0 -> 1
      _ -> target
    end
  end
end
