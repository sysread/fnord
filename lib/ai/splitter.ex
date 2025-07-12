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
    bespoke_tokens = AI.PretendTokenizer.guesstimate_tokens(bespoke_input)
    remaining_tokens = tok.model.context - bespoke_tokens

    if remaining_tokens <= 0 do
      {"", %{tok | done: true, input: ""}}
    else
      remaining_chars = remaining_tokens * 4
      {slice, remaining} = String.split_at(tok.input, remaining_chars)
      is_done? = remaining == ""
      {slice, %{tok | done: is_done?, input: remaining}}
    end
  end
end
