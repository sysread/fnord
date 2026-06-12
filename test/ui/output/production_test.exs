defmodule UI.Output.ProductionTest do
  use Fnord.TestCase, async: true

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

    # interact/1 has a fallback clause that raises RuntimeError for error
    # kinds other than exception/exit/throw. It is unreachable through the
    # real queue: UI.Queue.exec's `rescue` normalizes the entire :error class
    # into exception structs, so only {:exit, _} and {:throw, _} shapes ever
    # emerge (each covered above). The clause is defensive against future
    # queue error shapes and is intentionally untested.
  end

  # Note: choose/2 and prompt/1 are integration points with Owl.IO and Notifier,
  # which are not behaviour-backed. Those UI-level tests are better expressed
  # via the UI facade with Mox expectations on UI.Output.Mock rather than
  # mocking Owl.IO/Notifier in this module.
end
