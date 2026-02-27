defmodule Services.NamePoolNomenclaterRealTest do
  use Fnord.TestCase, async: false

  alias Services.NamePool

  setup do
    prev = Services.Globals.get_env(:fnord, :nomenclater, nil)
    Services.Globals.put_env(:fnord, :nomenclater, :real)

    on_exit(fn ->
      if is_nil(prev) do
        Services.Globals.delete_env(:fnord, :nomenclater)
      else
        Services.Globals.put_env(:fnord, :nomenclater, prev)
      end
    end)

    :ok
  end

  test "allocate chunk uses nomenclater to provide names" do
    NamePool.reset()

    # Intercept the agent-layer call to return a deterministic name batch
    :meck.new(AI.Agent, [:passthrough])

    :meck.expect(AI.Agent, :get_response, fn _agent, args ->
      want = Map.get(args, :want) || Map.get(args, "want") || 12
      # produce unique names each invocation to avoid collision when chunk_size is 1
      names = Enum.map(1..want, fn _ -> "NAME-#{:erlang.unique_integer([:positive])}" end)
      {:ok, names}
    end)

    on_exit(fn ->
      try do
        :meck.unload(AI.Agent)
      rescue
        _ -> :ok
      end
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
