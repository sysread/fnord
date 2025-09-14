defmodule UI.Output.Production.Test do
  use Fnord.TestCase, async: false

  describe "interact/1 returns and maps errors correctly" do
    test "returns value when underlying queue returns {:ok, value}" do
      assert UI.Output.Production.interact(fn -> :hello end) == :hello
    end

    test "raises exception on {:error,{exception,_}}" do
      assert_raise ArgumentError, "oops", fn ->
        UI.Output.Production.interact(fn -> raise ArgumentError, "oops" end)
      end
    end

    test "exits on {:error, {:exit, reason}}" do
      assert catch_exit(UI.Output.Production.interact(fn -> exit(:bye) end)) == :bye
    end

    test "throws on {:error, {:throw, value}}" do
      assert catch_throw(UI.Output.Production.interact(fn -> throw(:thrown) end)) == :thrown
    end

    test "fallback: raises RuntimeError for other error kinds" do
      # Force a non-standard error kind from the queue layer
      :meck.new(UI.Queue, [:passthrough])

      :meck.expect(UI.Queue, :interact, 2, fn _srv, _fun ->
        {:error, {:foo, "bar"}}
      end)

      on_exit(fn ->
        try do
          :meck.unload(UI.Queue)
        rescue
          _ -> :ok
        end
      end)

      assert_raise RuntimeError, "foo: \"bar\"", fn ->
        UI.Output.Production.interact(fn -> :unused end)
      end
    end
  end

  # Note: choose/2 and prompt/1 are integration points with Owl.IO and Notifier,
  # which are not behaviour-backed. Those UI-level tests are better expressed
  # via the UI facade with Mox expectations on UI.Output.Mock rather than
  # mecking Owl.IO/Notifier in this module.
end
