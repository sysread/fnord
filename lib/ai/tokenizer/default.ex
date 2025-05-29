defmodule AI.Tokenizer.Default do
  @moduledoc """
  Implements the default tokenizer behaviour for AI.Tokenizer.
  """

  @tokenizer %{
    "default" => AI.Tokenizer.Tokens_cl100k_base,
    "o3-mini" => AI.Tokenizer.Tokens_o200k_base,
    "gpt-4o" => AI.Tokenizer.Tokens_o200k_base,
    "gpt-4o-mini" => AI.Tokenizer.Tokens_o200k_base,
    "text-embedding-3-large" => AI.Tokenizer.Tokens_cl100k_base,
    "text-embedding-3-small" => AI.Tokenizer.Tokens_cl100k_base
  }

  # A special fallback token ID for unknown tokens
  @fallback_token 200_020

  # -----------------------------------------------------------------------------
  # Behaviour implementation
  # -----------------------------------------------------------------------------
  @behaviour AI.Tokenizer

  @impl AI.Tokenizer
  def encode(text, model) do
    tokenizer = get_tokenizer!(model)
    pattern = tokenizer.get_pattern()
    vocab = tokenizer.get_vocab()
    special = tokenizer.get_special_tokens()

    pattern
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.flat_map(fn piece ->
      apply_bpe(piece, tokenizer)
    end)
    |> Enum.map(fn token ->
      case Map.get(vocab, token) do
        nil ->
          case special[token] do
            nil -> {@fallback_token, token}
            special_id -> special_id
          end

        id ->
          id
      end
    end)
  end

  defp apply_bpe(piece, tokenizer) do
    merge_ranks = tokenizer.get_merge_ranks()
    # split into one-byte binaries
    tokens = piece |> :binary.bin_to_list() |> Enum.map(&<<&1>>)

    loop_merge(tokens, merge_ranks)
  end

  defp loop_merge(tokens, merge_ranks) do
    pairs = Enum.zip(tokens, Enum.drop(tokens, 1))

    # build list of {rank, merged_bytes, index, a, b}
    candidates =
      pairs
      |> Enum.with_index()
      |> Enum.reduce([], fn {{a, b}, idx}, acc ->
        merged = a <> b

        case Map.fetch(merge_ranks, merged) do
          {:ok, rank} ->
            [{rank, merged, idx, a, b} | acc]

          :error ->
            acc
        end
      end)

    case candidates do
      [] ->
        tokens

      _ ->
        # pick the candidate with the lowest rank
        {_, merged, idx, _a, _b} =
          Enum.min_by(candidates, fn {rank, _m, _i, _a, _b} -> rank end)

        {left, rest} = Enum.split(tokens, idx)
        # drop the two tokens we just merged
        [_a, _b | right] = rest
        # recurse on the new token list
        loop_merge(left ++ [merged] ++ right, merge_ranks)
    end
  end

  @impl AI.Tokenizer
  def decode(token_ids, model) do
    tokenizer = get_tokenizer!(model)
    rv = tokenizer.get_reverse_vocab()

    token_ids
    |> Enum.map(fn
      {@fallback_token, raw} ->
        raw

      id when is_integer(id) ->
        Map.get(rv, id, "")

      other ->
        IO.warn("Unexpected token in decode: #{inspect(other)}")
        ""
    end)
    |> Enum.join("")
  end

  defp get_tokenizer!(model) do
    Map.get(@tokenizer, model, @tokenizer["default"])
  end
end
