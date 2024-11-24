defmodule Indexer do
  @moduledoc """
  This behaviour wraps the AI-powered operations used by `Cmd.Indexer` to allow
  overrides for testing.
  """

  # Args
  @type indexer :: struct()
  @type file_path :: String.t()
  @type file_content :: String.t()

  # Return values
  @type completion :: {:ok, String.t()}
  @type embeddings :: {:ok, [String.t()]}
  @type error :: {:error, term()}

  # Callbacks
  @callback new() :: indexer
  @callback get_embeddings(indexer, file_path) :: embeddings | error
  @callback get_summary(indexer, file_path, file_content) :: completion | error
  @callback get_outline(indexer, file_path, file_content) :: completion | error

  @behaviour Indexer

  defstruct [:ai]

  @impl Indexer
  def new() do
    %__MODULE__{ai: AI.new()}
  end

  @impl Indexer
  def get_embeddings(indexer, text) do
    AI.get_embeddings(indexer.ai, text)
  end

  @impl Indexer
  def get_summary(indexer, file, text) do
    AI.Agent.FileSummary.get_summary(indexer.ai, file, text)
  end

  @impl Indexer
  def get_outline(indexer, file_path, file_content) do
    indexer.ai
    |> AI.Agent.CodeMapper.new(file_path, file_content)
    |> AI.Agent.CodeMapper.get_outline()
  end
end
