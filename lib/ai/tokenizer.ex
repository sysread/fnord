defmodule AI.Tokenizer do
  @moduledoc """
  > Oh yeah? I'm gonna make my own tokenizer, with blackjack and hookers!
                                                      -- ~Bender~ ChatGPT

  The only tokenizer modules available when this was written are either older
  and don't correctly count for OpenAI's newer models (Gpt3Tokenizer) or can't
  be used in an escript because they require priv access or OTP support beyond
  escript's abilities (Tokenizers).

  This module tokenizes text using the `o200k_base` vocabulary and merges files
  from OpenAI's tiktoken repo.
  """
  import AI.Tokens_o200k_base

  # -----------------------------------------------------------------------------
  # Behaviour definition
  # -----------------------------------------------------------------------------
  @callback decode(list()) :: String.t()
  @callback encode(String.t()) :: list()

  def get_impl() do
    Application.get_env(:fnord, :tokenizer_module) || __MODULE__
  end

  # -----------------------------------------------------------------------------
  # Behaviour implementation
  # -----------------------------------------------------------------------------
  @behaviour AI.Tokenizer

  @impl AI.Tokenizer
  def decode(token_ids) do
    Enum.map(token_ids, fn id ->
      # Return `nil` for unknown IDs
      Map.get(get_reverse_vocab(), id, nil)
    end)
    |> Enum.join("")
  end

  @impl AI.Tokenizer
  def encode(text) do
    # Step 1: Split text into initial tokens using the regex pattern
    tokens = Regex.scan(get_pattern(), text) |> List.flatten()

    # Step 2: Apply BPE merging
    bpe_tokens = Enum.map(tokens, &apply_bpe(&1))

    # Step 3: Map tokens to vocabulary IDs
    Enum.map(bpe_tokens, fn token ->
      Map.get(get_vocab(), token, get_special_tokens()[token] || nil)
    end)
  end

  # -----------------------------------------------------------------------------
  # Public functions
  # -----------------------------------------------------------------------------
  def chunk(input, max_tokens) do
    tokenizer = AI.Tokenizer.get_impl()

    input
    |> tokenizer.encode()
    |> Enum.chunk_every(max_tokens)
    |> Enum.map(&tokenizer.decode(&1))
  end

  # -----------------------------------------------------------------------------
  # Private functions
  # -----------------------------------------------------------------------------
  defp apply_bpe(token) do
    # Split token into characters for BPE merging
    chars = String.graphemes(token)

    # Merge adjacent pairs based on BPE rules
    loop_merge(chars)
  end

  defp loop_merge(tokens) do
    tokens
    # Create pairs of adjacent tokens
    |> Enum.zip(Enum.drop(tokens, 1))
    # Find the first pair that exists in the merge rules
    |> Enum.find(&MapSet.member?(get_merges(), &1))
    |> case do
      # No more pairs to merge, return the tokens as a single string
      nil ->
        Enum.join(tokens, "")

      # Merge the pair and continue
      pair ->
        tokens
        |> Enum.reduce([], fn token, acc ->
          case acc do
            # Merge the pair into one token
            [last | rest] when {last, token} == pair ->
              [Enum.join(Tuple.to_list(pair), "") | rest]

            # Add the token to the accumulator as-is
            _ ->
              [token | acc]
          end
        end)
        |> Enum.reverse()
        # Recursive call to merge further
        |> loop_merge()
    end
  end
end
