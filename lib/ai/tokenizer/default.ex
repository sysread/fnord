defmodule AI.Tokenizer.Default do
  @moduledoc """
  Implements the default tokenizer behaviour for AI.Tokenizer.
  """

  @tokenizer %{
    "gpt-4o" => AI.Tokenizer.Tokens_o200k_base,
    "gpt-4o-mini" => AI.Tokenizer.Tokens_o200k_base,
    "text-embedding-3-large" => AI.Tokenizer.Tokens_cl100k_base
  }

  # -----------------------------------------------------------------------------
  # Behaviour implementation
  # -----------------------------------------------------------------------------
  @behaviour AI.Tokenizer

  @impl AI.Tokenizer
  def decode(token_ids, model) do
    tokenizer = get_tokenizer!(model)
    reverse_vocab = tokenizer.get_reverse_vocab()

    token_ids
    |> Enum.map(&Map.get(reverse_vocab, &1, ""))
    |> Enum.join("")
  end

  @impl AI.Tokenizer
  def encode(text, model) do
    tokenizer = get_tokenizer!(model)
    pattern = tokenizer.get_pattern()
    vocab = tokenizer.get_vocab()
    special_tokens = tokenizer.get_special_tokens()

    try do
      # Step 1: Split text with the tokenizer-specific pattern
      pattern
      |> Regex.scan(text)
      |> List.flatten()
      # Step 2: Apply byte pair encoding merging
      |> Enum.map(&apply_bpe(&1, model))
      # Step 3: Map tokens to vocabulary IDs
      |> Enum.map(&Map.get(vocab, &1, special_tokens[&1] || nil))
    rescue
      e in ArgumentError ->
        IO.inspect(text, label: "Input text (raw)", limit: :infinity)
        {:error, e}
    end
  end

  # -----------------------------------------------------------------------------
  # Private functions
  # -----------------------------------------------------------------------------
  defp get_tokenizer!(model) do
    tokenizer = @tokenizer[model]

    if is_nil(tokenizer) do
      raise ArgumentError, "Unknown model: #{model}"
    end

    tokenizer
  end

  defp apply_bpe(token, model) do
    token
    |> String.graphemes()
    |> loop_merge(model)
  end

  # Merge adjacent pairs based on BPE rules
  defp loop_merge(tokens, model) do
    tokenizer = get_tokenizer!(model)

    tokens
    # Create pairs of adjacent tokens
    |> Enum.zip(Enum.drop(tokens, 1))
    # Find the first pair that exists in the merge rules
    |> Enum.find(&MapSet.member?(tokenizer.get_merges(), &1))
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
        |> loop_merge(model)
    end
  end
end
