defmodule AIAgentHttpPoolTest do
  use Fnord.TestCase, async: false

  alias HttpPool
  alias AI.Agent

  # Dummy implementation for testing: returns the current HttpPool.get()
  defmodule DummyAgentImpl do
    @behaviour Agent

    @impl true
    def get_response(_args) do
      # Return the current pool assignment
      {:ok, HttpPool.get()}
    end
  end

  setup do
    HttpPool.clear()
    :ok
  end

  test "get_response returns default pool when no override set" do
    agent = Agent.new(DummyAgentImpl, named?: false)
    assert {:ok, :ai_api} == Agent.get_response(agent, %{})
  end

  test "get_response propagates override into spawned Task" do
    HttpPool.set(:ai_indexer)
    agent = Agent.new(DummyAgentImpl, named?: false)

    assert {:ok, :ai_indexer} == Agent.get_response(agent, %{})

    HttpPool.clear()
  end
end
