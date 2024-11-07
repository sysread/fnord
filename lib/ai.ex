defmodule AI do
  @moduledoc """
  AI is a behavior module that defines the interface for interacting with
  OpenAI's API. It provides a common interface for the various OpenAI-powered
  operations used by the application.
  """

  defstruct [:client]

  @api_key System.get_env("OPENAI_API_KEY")
  @api_timeout 45_000

  @callback new() :: struct()
  @callback get_embeddings(struct(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  @callback get_summary(struct(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}

  @behaviour AI

  @impl AI
  @doc """
  Create a new AI instance. Instances share the same client connection.
  """
  def new() do
    openai =
      @api_key
      |> OpenaiEx.new()
      |> OpenaiEx.with_receive_timeout(@api_timeout)

    %AI{client: openai}
  end

  # -----------------------------------------------------------------------------
  # Embeddings
  # -----------------------------------------------------------------------------
  @impl AI
  @doc """
  See `AI.Embeddings.get_embeddings/2`.
  """
  defdelegate get_embeddings(ai, text), to: AI.Embeddings

  # -----------------------------------------------------------------------------
  # Summaries
  # -----------------------------------------------------------------------------
  @impl AI
  @doc """
  See `AI.Summarizer.get_summary/3`.
  """
  defdelegate get_summary(ai, file, text), to: AI.Summarizer

  # -----------------------------------------------------------------------------
  # Answers
  # -----------------------------------------------------------------------------
  defdelegate system_message(), to: AI.Answers
  defdelegate assistant_message(msg), to: AI.Answers
  defdelegate assistant_tool_message(id, func, args), to: AI.Answers
  defdelegate user_message(msg), to: AI.Answers
  defdelegate tool_message(id, func, output), to: AI.Answers
  defdelegate stream(ai, messages), to: AI.Answers
end
