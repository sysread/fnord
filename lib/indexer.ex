defmodule Indexer do
  @moduledoc """
  This behaviour wraps the AI-powered operations used by `Cmd.Index` to allow
  overrides for testing. See `impl/0`.
  """

  # -----------------------------------------------------------------------------
  # Input Types
  # -----------------------------------------------------------------------------
  @type indexer :: module()
  @type file_path :: String.t()
  @type file_content :: String.t()

  # -----------------------------------------------------------------------------
  # Output Types
  # -----------------------------------------------------------------------------
  @type completion :: {:ok, String.t()}
  @type embeddings :: {:ok, [float]}
  @type error :: {:error, term}

  # -----------------------------------------------------------------------------
  # Behaviour Definition
  # -----------------------------------------------------------------------------
  @callback get_embeddings(file_content) :: embeddings | error
  @callback get_summary(file_path, file_content) :: completion | error
  @callback get_outline(file_path, file_content) :: completion | error

  # -----------------------------------------------------------------------------
  # Behaviour Implementation
  # -----------------------------------------------------------------------------
  @behaviour Indexer

  @impl Indexer
  def get_embeddings(content) do
    AI.Embeddings.get(content)
  end

  @impl Indexer
  def get_summary(file, content) do
    AI.Agent.FileSummary.get_response(%{file: file, content: content})
  end

  @impl Indexer
  def get_outline(file, content) do
    AI.Agent.CodeMapper.get_response(%{file: file, content: content})
  end

  # -----------------------------------------------------------------------------
  # API Functions
  # -----------------------------------------------------------------------------
  @doc """
  Returns the current indexer module. This can be overridden by config for unit
  testing. See `test/test_helper.exs`.
  """
  def impl() do
    Application.get_env(:fnord, :indexer) || __MODULE__
  end
end
