defmodule AI.Tokenizer do
  @moduledoc """
  > Oh yeah? I'm gonna make my own tokenizer, with blackjack and hookers!
                                                      -- ~Bender~ ChatGPT

  The only tokenizer modules available for elixir when this was written are
  either older and don't correctly count for OpenAI's newer models
  (Gpt3Tokenizer) or can't be used in an escript because they require priv
  access or OTP support beyond escript's abilities (Tokenizers).
  """

  @default_impl AI.Tokenizer.Default

  # -----------------------------------------------------------------------------
  # Behaviour definition
  # -----------------------------------------------------------------------------
  @callback decode(
              token_ids :: list(),
              model :: String.t()
            ) :: String.t()

  @callback encode(
              text :: String.t(),
              model :: String.t()
            ) :: list()

  # -----------------------------------------------------------------------------
  # Public functions
  # -----------------------------------------------------------------------------
  @doc """
  Returns the tokenizer implementation module currently in use. This is defined
  in the application config, under `fnord/tokenizer_module`, allowing it to be
  overridden for testing.
  """
  def get_impl() do
    Application.get_env(:fnord, :tokenizer_module) || @default_impl
  end

  @doc """
  Encodes a text string into a list of token IDs using the algorithm defined
  for the specified model.
  """
  def encode(text, model) do
    get_impl().encode(text, model)
  end

  @doc """
  Decodes a list of token IDs into a text string using the algorithm defined
  for the specified model.
  """
  def decode(token_ids, model) do
    get_impl().decode(token_ids, model)
  end

  @doc """
  Splits a string into chunks of `max_tokens` tokens using the algorithm
  defined for the specified model.
  """
  def chunk(input, max_tokens, model) do
    tokenizer = AI.Tokenizer.get_impl()

    input
    |> tokenizer.encode(model)
    |> Enum.chunk_every(max_tokens)
    |> Enum.map(&tokenizer.decode(&1, model))
  end
end
