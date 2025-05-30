defmodule StubIndexer do
  @moduledoc """
  The default test implementation for `MockIndexer`.
  """

  defstruct []

  @behaviour Indexer

  @impl Indexer
  def get_embeddings(_content), do: {:ok, [1, 2, 3]}

  @impl Indexer
  def get_summary(_file, _content), do: {:ok, "summary"}

  @impl Indexer
  def get_outline(_file, _content), do: {:ok, "outline"}
end
