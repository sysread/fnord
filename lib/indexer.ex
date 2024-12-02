defmodule Indexer do
  @moduledoc """
  This behaviour wraps the AI-powered operations used by `Cmd.Indexer` to allow
  overrides for testing.
  """

  # -----------------------------------------------------------------------------
  # Input Types
  # -----------------------------------------------------------------------------
  @type indexer :: struct()
  @type file_path :: String.t()
  @type file_content :: String.t()

  # -----------------------------------------------------------------------------
  # Output Types
  # -----------------------------------------------------------------------------
  @type completion :: {:ok, String.t()}
  @type embeddings :: {:ok, [String.t()]}
  @type error :: {:error, term()}

  # -----------------------------------------------------------------------------
  # Behaviour Definition
  # -----------------------------------------------------------------------------
  @callback new() :: indexer
  @callback get_embeddings(indexer, file_path) :: embeddings | error
  @callback get_summary(indexer, file_path, file_content) :: completion | error
  @callback get_outline(indexer, file_path, file_content) :: completion | error

  # -----------------------------------------------------------------------------
  # Behaviour Implementation
  # -----------------------------------------------------------------------------
  @behaviour Indexer

  defstruct [:ai]

  @impl Indexer
  def new() do
    %__MODULE__{ai: AI.new()}
  end

  @impl Indexer
  def get_embeddings(indexer, content) do
    AI.get_embeddings(indexer.ai, content)
  end

  @impl Indexer
  def get_summary(indexer, file, content) do
    AI.Agent.FileSummary.get_response(indexer.ai, %{file: file, content: content})
  end

  @impl Indexer
  def get_outline(indexer, file, content) do
    AI.Agent.CodeMapper.get_response(indexer.ai, %{file: file, content: content})
  end
end
