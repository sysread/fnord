defmodule AI.Agent.CoordinatorLongTermAccessTest do
  use Fnord.TestCase, async: false

  test "Coordinator toolbox does not expose long_term_memory_tool" do
    toolbox = AI.Tools.basic_tools()
    refute Map.has_key?(toolbox, "long_term_memory_tool")
  end
end
