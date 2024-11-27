defmodule AI.Tokenizer.Splitter do
  @moduledoc """
  This module is used to split a string into chunks by the number of tokens,
  while accounting for *other* data that might be going with it to the API
  endpoint with the limited token count.

  For example, the search entry agent may be processing a large file, one that
  must be split into 3 slices just to fit it into the payload of an API call.
  In order to retain context between chunks, the agent essentially _reduces_
  over the file, keeping track of information in the previous chunks to
  generate a final summary. Doing that means that we need to not only split the
  file by the number of tokens in each slice, but also keep some space for the
  bespoke data that will be added to the payload as the agent's "accumulator".
  """

  defstruct [
    :tokenizer,
    :max_tokens,
    :input,
    :input_tokens,
    :offset,
    :done
  ]

  def new(input, max_tokens, tokenizer \\ AI.Tokenizer) do
    %AI.Tokenizer.Splitter{
      tokenizer: tokenizer,
      max_tokens: max_tokens,
      input: input,
      input_tokens: tokenizer.encode(input),
      offset: 0,
      done: false
    }
  end

  def next_chunk(%AI.Tokenizer.Splitter{done: true} = tok, _bespoke_input) do
    {:done, tok}
  end

  def next_chunk(tok, bespoke_input) do
    bespoke_tokens = tok.tokenizer.encode(bespoke_input) |> length()
    remaining_tokens = tok.max_tokens - bespoke_tokens
    {slice, tok} = get_slice(tok, remaining_tokens)

    tok =
      if tok.offset >= length(tok.input_tokens) do
        %AI.Tokenizer.Splitter{tok | done: true}
      else
        tok
      end

    {slice, tok}
  end

  defp get_slice(%AI.Tokenizer.Splitter{done: true} = tok, _num_tokens) do
    {"", tok}
  end

  defp get_slice(tok, num_tokens) do
    slice = Enum.slice(tok.input_tokens, tok.offset, num_tokens)
    tokens = length(slice)
    output = tok.tokenizer.decode(slice)
    {output, %AI.Tokenizer.Splitter{tok | offset: tok.offset + tokens}}
  end
end
