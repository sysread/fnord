defmodule AI.Tokenizer do
  @moduledoc """
  > Oh yeah? I'm gonna make my own tokenizer, with blackjack and hookers!
                                                      -- ~Bender~ ChatGPT

  The only tokenizer modules available when this was written are either older
  and don't correctly count for OpenAI's newer models (Gpt3Tokenizer) or can't
  be used in an escript because they require priv access or OTP support beyond
  escript's abilities (Tokenizers).
  """
  @behaviour AI.Tokenizer.Behaviour

  @merges :erlang.binary_to_term(File.read!("data/o200k_base.merges"))
  @vocab :erlang.binary_to_term(File.read!("data/o200k_base.vocab"))
  @reverse_vocab :erlang.binary_to_term(File.read!("data/o200k_base.reverse_vocab"))

  @pattern ~r<[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]*[\p{Ll}\p{Lm}\p{Lo}\p{M}]+(?i:'s|'t|'re|'ve|'m|'ll|'d)?|[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]+[\p{Ll}\p{Lm}\p{Lo}\p{M}]*(?i:'s|'t|'re|'ve|'m|'ll|'d)?|\p{N}{1,3}| ?[^\s\p{L}\p{N}]+[\r\n/]*|\s*[\r\n]+|\s+(?!\S)|\s+>

  @special_tokens %{
    "<|endoftext|>" => 199_999,
    "<|endofprompt|>" => 200_018
  }

  @impl AI.Tokenizer.Behaviour
  def decode(token_ids) do
    Enum.map(token_ids, fn id ->
      # Return `nil` for unknown IDs
      Map.get(@reverse_vocab, id, nil)
    end)
    |> Enum.join("")
  end

  @impl AI.Tokenizer.Behaviour
  def encode(text) do
    # Step 1: Split text into initial tokens using the regex pattern
    tokens = Regex.scan(@pattern, text) |> List.flatten()

    # Step 2: Apply BPE merging
    bpe_tokens = Enum.map(tokens, &apply_bpe(&1))

    # Step 3: Map tokens to vocabulary IDs
    Enum.map(bpe_tokens, fn token ->
      Map.get(@vocab, token, @special_tokens[token] || nil)
    end)
  end

  defp apply_bpe(token) do
    # Split token into characters for BPE merging
    chars = String.graphemes(token)

    # Merge adjacent pairs based on BPE rules until no further merges can be applied
    loop_merge(chars)
  end

  defp loop_merge(tokens) do
    # Create pairs of adjacent tokens
    pairs = Enum.zip(tokens, Enum.drop(tokens, 1))

    # Find the first pair that exists in the merge rules
    case Enum.find(pairs, &MapSet.member?(@merges, &1)) do
      nil ->
        # No more pairs to merge, return the tokens as a single string
        Enum.join(tokens, "")

      pair ->
        # Merge the pair and continue
        merged_tokens =
          tokens
          |> Enum.reduce([], fn token, acc ->
            case acc do
              [last | rest] when {last, token} == pair ->
                # Merge the pair into one token
                [Enum.join(Tuple.to_list(pair), "") | rest]

              _ ->
                # Add the token to the accumulator as-is
                [token | acc]
            end
          end)
          |> Enum.reverse()

        # Recursive call to merge further
        loop_merge(merged_tokens)
    end
  end
end
