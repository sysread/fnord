defmodule Services.NamePoolNomenclaterRealTest do
  use Fnord.TestCase, async: true

  alias Services.NamePool

  setup do
    # TestCase defaults :nomenclater to :fake; this suite exercises the :real
    # path, where NamePool invokes the Nomenclater agent for name batches.
    set_config(:nomenclater, :real)
    :ok
  end

  test "allocate chunk uses nomenclater to provide names" do
    NamePool.reset()

    # Canned-respond at the agent-dispatch seam with a deterministic name
    # batch. AI.Agent.get_response's bookkeeping still runs for real - this
    # verifies NamePool's plumbing to the agent layer, not the agent itself.
    canned_agent(fn AI.Agent.Nomenclater, args ->
      want = Map.get(args, :want) || 12
      # produce unique names each invocation to avoid collision when chunk_size is 1
      names = Enum.map(1..want, fn _ -> "NAME-#{:erlang.unique_integer([:positive])}" end)
      {:ok, names}
    end)

    # Checkout a few names and ensure they are unique
    names =
      1..4
      |> Enum.map(fn _ ->
        assert {:ok, name} = NamePool.checkout_name()
        assert is_binary(name)
        name
      end)

    assert length(Enum.uniq(names)) == 4
  end
end
