defmodule StubIndexer do
  @moduledoc """
  The default test implementation for `MockIndexer`.
  """

  defstruct []

  @behaviour Indexer

  @impl Indexer
  # 384-dimensional stub vector matching the local MiniLM-L12-v2 model dimensions
  def get_embeddings(_content), do: {:ok, List.duplicate(0.1, 384)}

  @impl Indexer
  def get_summary(_file, _content), do: {:ok, "summary"}
end
