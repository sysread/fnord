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
  in the application config, under `fnord/tokenizer`, allowing it to be
  overridden for testing.
  """
  def impl() do
    Application.get_env(:fnord, :tokenizer) || @default_impl
  end

  @doc """
  Encodes a text string into a list of token IDs using the algorithm defined
  for the specified model.
  """
  def encode(text, model) when is_binary(model), do: impl().encode(text, model)
  def encode(text, model), do: impl().encode(text, model.model)

  @doc """
  Decodes a list of token IDs into a text string using the algorithm defined
  for the specified model.
  """
  def decode(token_ids, model) when is_binary(model), do: impl().decode(token_ids, model)
  def decode(token_ids, model), do: impl().decode(token_ids, model.model)

  @doc """
  Splits a string into chunks of `model.context` tokens using the algorithm
  defined for the specified model.
  """
  def chunk(input, model) do
    input
    |> encode(model)
    |> Enum.chunk_every(model.context)
    |> Enum.map(&decode(&1, model))
  end
end
