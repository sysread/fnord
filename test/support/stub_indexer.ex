defmodule StubIndexer do
  @moduledoc """
  The default test implementation for `MockIndexer`.
  """

  defstruct []

  @behaviour Indexer

  @impl Indexer
  def new, do: %StubIndexer{}

  @impl Indexer
  def get_embeddings(_indexer, _content), do: {:ok, [1, 2, 3]}

  @impl Indexer
  def get_summary(_indexer, _file, _content), do: {:ok, "summary"}

  @impl Indexer
  def get_outline(_indexer, _file, _content), do: {:ok, "outline"}
end
