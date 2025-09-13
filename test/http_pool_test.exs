defmodule HttpPoolTest do
  use Fnord.TestCase, async: true

  alias HttpPool

  setup do
    HttpPool.clear()
    :ok
  end

  test "default pool is :ai_api" do
    assert HttpPool.get() == :ai_api
  end

  test "set override to :ai_indexer" do
    HttpPool.set(:ai_indexer)
    assert HttpPool.get() == :ai_indexer
  end

  test "clear resets to default pool" do
    HttpPool.set(:ai_indexer)
    HttpPool.clear()
    assert HttpPool.get() == :ai_api
  end
end
