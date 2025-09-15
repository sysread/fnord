defmodule HttpPoolTest do
  use Fnord.TestCase

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

  describe "with_pool/2" do
    test "sets override and restores default when no previous override exists" do
      # No prior override: get/0 should default to :ai_api
      assert HttpPool.get() == :ai_api

      # with_pool should apply override inside the function
      result =
        HttpPool.with_pool(:foo_pool, fn ->
          assert HttpPool.get() == :foo_pool
          :ok_value
        end)

      # Should return the function result
      assert result == :ok_value

      # After with_pool, override should be cleared back to default
      assert HttpPool.get() == :ai_api
    end

    test "restores previous override when one existed before" do
      # Set an initial override
      HttpPool.set(:initial_pool)
      assert HttpPool.get() == :initial_pool

      # with_pool should override temporarily
      HttpPool.with_pool(:inner_pool, fn ->
        assert HttpPool.get() == :inner_pool
      end)

      # After with_pool, original override should be restored
      assert HttpPool.get() == :initial_pool
    end

    test "restores previous override even if function raises" do
      HttpPool.set(:before_pool)
      assert HttpPool.get() == :before_pool

      # Trigger an exception inside with_pool
      assert_raise RuntimeError, "oops", fn ->
        HttpPool.with_pool(:will_fail, fn ->
          assert HttpPool.get() == :will_fail
          raise "oops"
        end)
      end

      # After exception, override should still be restored
      assert HttpPool.get() == :before_pool
    end

    test "nested with_pool blocks restore in proper LIFO order" do
      # No prior override: default is :ai_api
      assert HttpPool.get() == :ai_api

      HttpPool.with_pool(:outer, fn ->
        assert HttpPool.get() == :outer

        HttpPool.with_pool(:inner, fn ->
          # Inner override
          assert HttpPool.get() == :inner
        end)

        # After inner block unwinds, we should be back to outer
        assert HttpPool.get() == :outer
      end)

      # After both unwind, we should be back to default
      assert HttpPool.get() == :ai_api
    end
  end
end
