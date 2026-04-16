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
  Indexes a single entry: reads the source, generates the summary, computes
  embeddings, and persists everything. Returns the entry struct on success so
  callers can immediately read its data.

  This is the canonical single-file indexing pipeline, used by `Cmd.Index`
  for bulk indexing.
  """
  @spec index_entry(Store.Project.Entry.t()) ::
          {:ok, Store.Project.Entry.t()} | {:error, term}
  def index_entry(entry) do
    indexer = impl()

    with {:ok, contents} <- Store.Project.Entry.read_source_file(entry),
         :ok <- guard_text(contents),
         {:ok, summary} <- indexer.get_summary(entry.file, contents),
         {:ok, embeddings} <- get_file_embeddings(indexer, entry.file, summary),
         :ok <- Store.Project.Entry.save(entry, summary, embeddings) do
      {:ok, entry}
    end
  end

  # Downstream text-splitting (AI.Splitter / String.split_at) assumes a
  # valid UTF-8 binary. Tracked binaries (images, compiled assets, anything
  # the user has in .gitattributes or just hasn't excluded) would crash the
  # grapheme walker. Bail out here with a structured error so the caller
  # can classify the entry as skipped rather than a failure.
  defp guard_text(content) do
    if String.valid?(content), do: :ok, else: {:error, :binary_file}
  end

  # Build the embedding input from the file summary. The local embedding model
  # (all-MiniLM-L12-v2) has a 256-token window optimized for natural language,
  # so we embed the LLM-generated prose summary rather than raw code.
  defp get_file_embeddings(indexer, file, summary) do
    to_embed = """
    # File
    `#{file}`

    ## Summary
    #{summary}
    """

    indexer.get_embeddings(to_embed)
  end
end
