defmodule AI.Splitter do
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
    :model,
    :input,
    :done
  ]

  @type t :: %__MODULE__{
          model: AI.Model.t(),
          input: binary,
          done: boolean
        }

  def new(input, model) do
    %AI.Splitter{
      model: model,
      input: input,
      done: false
    }
  end

  def next_chunk(%AI.Splitter{done: true} = tok, _bespoke_input) do
    {:done, tok}
  end

  def next_chunk(tok, bespoke_input) do
    next_chunk(tok, bespoke_input, nil)
  end

  @doc """
  Returns the next chunk and updated splitter state, accounting for the bespoke input tokens.

  Optionally, a `max_chunk_tokens` can be provided to limit the chunk size explicitly.
  """
  def next_chunk(tok, bespoke_input, max_chunk_tokens) do
    bespoke_tokens = AI.PretendTokenizer.guesstimate_tokens(bespoke_input)
    max_tokens = max_chunk_tokens || max_tokens(tok.model)
    remaining_tokens = max_tokens - bespoke_tokens

    next_chunk_result(tok, remaining_tokens)
  end

  defp next_chunk_result(tok, remaining_tokens) when remaining_tokens <= 0 do
    exhausted_budget_result(tok)
  end

  defp next_chunk_result(tok, remaining_tokens) do
    split_by_remaining_budget(tok, remaining_tokens)
  end

  defp exhausted_budget_result(tok) do
    {"", %{tok | done: true, input: ""}}
  end

  defp split_by_remaining_budget(tok, remaining_tokens) do
    remaining_chars = remaining_tokens * estimated_chars_per_token()
    {slice, remaining} = String.split_at(tok.input, remaining_chars)
    {slice, %{tok | done: remaining == "", input: remaining}}
  end

  defp estimated_chars_per_token do
    3
  end

  defp max_tokens(model) do
    # Leave some space since we just guestimate token counts
    round(model.context * 0.9)
  end
end
