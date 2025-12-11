defmodule AI.Tools.PlanTest do
  use Fnord.TestCase, async: false

  describe "spec/0" do
    test "defines the plan_tool function" do
      spec = AI.Tools.Plan.spec()
      function = spec["function"] || spec[:function]

      assert (function["name"] || function[:name]) == "plan_tool"
    end
  end
end
