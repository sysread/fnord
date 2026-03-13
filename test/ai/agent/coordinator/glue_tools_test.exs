defmodule AI.Agent.Coordinator.GlueToolsTest do
  use Fnord.TestCase, async: false

  setup do
    set_log_level(:none)

    :meck.new(UI, [:passthrough])

    on_exit(fn ->
      try do
        :meck.unload(UI)
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  test "coordinator includes ui tools only when tty and not quiet" do
    :meck.expect(UI, :is_tty?, 0, true)
    :meck.expect(UI, :quiet?, 0, false)

    for edit <- [false, true] do
      tools = AI.Agent.Coordinator.Glue.get_tools(%{edit?: edit})

      assert Map.has_key?(tools, "ui_ask_tool")
      assert Map.has_key?(tools, "ui_choose_tool")
      assert Map.has_key?(tools, "ui_confirm_tool")
    end
  end

  test "coordinator excludes ui tools when not a tty" do
    :meck.expect(UI, :is_tty?, 0, false)
    :meck.expect(UI, :quiet?, 0, false)

    for edit <- [false, true] do
      tools = AI.Agent.Coordinator.Glue.get_tools(%{edit?: edit})

      refute Map.has_key?(tools, "ui_ask_tool")
      refute Map.has_key?(tools, "ui_choose_tool")
      refute Map.has_key?(tools, "ui_confirm_tool")
    end
  end

  test "coordinator excludes ui tools when quiet" do
    :meck.expect(UI, :is_tty?, 0, true)
    :meck.expect(UI, :quiet?, 0, true)

    for edit <- [false, true] do
      tools = AI.Agent.Coordinator.Glue.get_tools(%{edit?: edit})

      refute Map.has_key?(tools, "ui_ask_tool")
      refute Map.has_key?(tools, "ui_choose_tool")
      refute Map.has_key?(tools, "ui_confirm_tool")
    end
  end
end
