defmodule AI.Tokenizer.Tokens_o200k_base do
  @moduledoc """
  This module implements the o200k-base tokenizer model used by OpenAI's
  `gpt-4o` models.
  """

  @merges_list :erlang.binary_to_term(File.read!("data/tokens/o200k_base.merges"))
  @vocab :erlang.binary_to_term(File.read!("data/tokens/o200k_base.vocab"))
  @reverse_vocab :erlang.binary_to_term(File.read!("data/tokens/o200k_base.reverse_vocab"))
  @merge_ranks Enum.with_index(@merges_list) |> Map.new(fn {bytes, idx} -> {bytes, idx} end)

  @special_tokens %{
    "<|endoftext|>" => 199_999,
    "<|endofprompt|>" => 200_018
  }

  # Source: https://github.com/openai/tiktoken/blob/main/tiktoken_ext/openai_public.py
  @pattern ~r<
    [^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]*[\p{Ll}\p{Lm}\p{Lo}\p{M}]+(?i:'s|'t|'re|'ve|'m|'ll|'d)?
  | [^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]+[\p{Ll}\p{Lm}\p{Lo}\p{M}]*(?i:'s|'t|'re|'ve|'m|'ll|'d)?
  | \p{N}{1,3}
  | [ ]?[^\s\p{L}\p{N}]+[\r\n/]*  
  | \s*[\r\n]+                
  | \s+(?!\S)                  
  | \s+                       
  >xu

  def get_merges(), do: @merges_list
  def get_merge_ranks(), do: @merge_ranks
  def get_vocab(), do: @vocab
  def get_reverse_vocab(), do: @reverse_vocab
  def get_special_tokens(), do: @special_tokens
  def get_pattern(), do: @pattern
end
