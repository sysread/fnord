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
    AI.Agent.FileSummary
    |> AI.Agent.new(named?: false)
    |> AI.Agent.get_response(%{file: file, content: content})
  end

  @impl Indexer
  def get_outline(file, content) do
    AI.Agent.CodeMapper
    |> AI.Agent.new(named?: false)
    |> AI.Agent.get_response(%{file: file, content: content})
  end

  # -----------------------------------------------------------------------------
  # API Functions
  # -----------------------------------------------------------------------------
  @doc """
  Returns the current indexer module. This can be overridden by config for unit
  testing. See `test/test_helper.exs`.
  """
  def impl() do
    Services.Globals.get_env(:fnord, :indexer) || __MODULE__
  end

  @doc """
  Indexes a single entry: reads the source, generates summary and outline in
  parallel, computes embeddings, and persists everything. Returns the entry
  struct on success so callers can immediately read its data.

  This is the canonical single-file indexing pipeline, used by `Cmd.Index`
  for bulk indexing.
  """
  @spec index_entry(Store.Project.Entry.t()) ::
          {:ok, Store.Project.Entry.t()} | {:error, term}
  def index_entry(entry) do
    indexer = impl()

    with {:ok, contents} <- Store.Project.Entry.read_source_file(entry),
         {:ok, summary, outline} <- get_derivatives(indexer, entry.file, contents),
         {:ok, embeddings} <- get_file_embeddings(indexer, entry.file, summary, outline, contents),
         :ok <- Store.Project.Entry.save(entry, summary, outline, embeddings) do
      {:ok, entry}
    end
  end

  # Generate summary and outline concurrently using the configured indexer impl.
  defp get_derivatives(indexer, file, contents) do
    summary_task = Services.Globals.Spawn.async(fn -> indexer.get_summary(file, contents) end)
    outline_task = Services.Globals.Spawn.async(fn -> indexer.get_outline(file, contents) end)

    with {:ok, summary} <- Task.await(summary_task, :infinity),
         {:ok, outline} <- Task.await(outline_task, :infinity) do
      {:ok, summary, outline}
    end
  end

  # Build the embedding input from the file's derivatives and content, matching
  # the format used by Cmd.Index.get_embeddings/4.
  defp get_file_embeddings(indexer, file, summary, outline, contents) do
    to_embed = """
    # File
    `#{file}`

    ## Summary
    #{summary}

    ## Outline
    #{outline}

    ## Contents
    ```
    #{contents}
    ```
    """

    indexer.get_embeddings(to_embed)
  end
end
