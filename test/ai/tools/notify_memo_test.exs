defmodule AI.Tools.NotifyMemoTest do
  use Fnord.TestCase, async: false

  setup do
    :meck.new(Services.NamePool, [:no_link, :passthrough, :non_strict])
    :meck.expect(Services.NamePool, :get_name_by_pid, fn _pid -> {:ok, "AgentX"} end)
    :meck.expect(Services.NamePool, :default_name, fn -> "DefaultAgent" end)

    :meck.new(UI, [:no_link, :passthrough, :non_strict])

    :meck.expect(UI, :feedback, fn level, name, message ->
      send(self(), {:feedback, level, name, message})
      :ok
    end)

    :meck.new(Services.Globals.Spawn, [:no_link, :passthrough, :non_strict])
    :meck.expect(Services.Globals.Spawn, :async, fn fun -> fun.() end)

    :meck.new(Services.Notes, [:no_link, :passthrough, :non_strict])

    :meck.expect(Services.Notes, :ingest_user_msg, fn msg ->
      send(self(), {:ingest, msg})
      :ok
    end)

    on_exit(fn ->
      :meck.unload(Services.NamePool)
      :meck.unload(UI)
      :meck.unload(Services.Globals.Spawn)
      :meck.unload(Services.Notes)
    end)

    :ok
  end

  describe "memo ingestion" do
    test "single memo line" do
      message = "note to self: Remember to hydrate"
      assert :ok == AI.Tools.Notify.call(%{"level" => "info", "message" => message})
      assert_received {:ingest, "Remember to hydrate"}
      assert_received {:feedback, :info, "AgentX", ^message}
    end

    test "multiple memo lines with whitespace and case-insensitive" do
      message = "start\n  Remember: add tests\nmiddle\nnote to self: finalize soon\nend"
      assert :ok == AI.Tools.Notify.call(%{"level" => "info", "message" => message})
      assert_received {:ingest, "add tests"}
      assert_received {:ingest, "finalize soon"}
      assert_received {:feedback, :info, "AgentX", ^message}
    end

    test "no memo lines" do
      message = "this is a regular message"
      assert :ok == AI.Tools.Notify.call(%{"level" => "warn", "message" => message})
      refute_received {:ingest, _}
      assert_received {:feedback, :warn, "AgentX", ^message}
    end
  end
end
