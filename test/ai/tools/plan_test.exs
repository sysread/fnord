defmodule AI.Tools.PlanTest do
  use Fnord.TestCase, async: false

  describe "spec/0" do
    test "defines the plan_tool function" do
      spec = AI.Tools.Plan.spec()
      function = spec["function"] || spec[:function]

      assert (function["name"] || function[:name]) == "plan_tool"
    end
  end
  
  describe "call/1 with meta_delta" do
    setup do
      project = mock_project("plan_test_project")
      {:ok, store_project} = Store.get_project("plan_test_project")
      %{project: project, store_project: store_project}
    end

    test "creates new plan file when plan is missing", %{store_project: store_project} do
      plan_name = "new_plan"
      meta_delta = %{"foo" => "bar"}

      AI.Tools.Plan.call(%{"plan_name" => plan_name, "meta_delta" => meta_delta})

      path = Store.Project.Plan.plan_path(store_project, plan_name)
      assert File.exists?(path)

      %{"meta" => meta} = path |> File.read!() |> Jason.decode!()
      assert meta["foo"] == "bar"
      assert is_binary(meta["updated_at"])
    end

    test "merges meta_delta and preserves unrelated keys for existing plan", %{store_project: store_project} do
      plan_name = "existing_plan"
      initial_meta = %{"a" => 1, "b" => 2}

      AI.Tools.Plan.call(%{"plan_name" => plan_name, "meta_delta" => initial_meta})
      :timer.sleep(1)
      new_delta = %{"b" => 3, "c" => 4}

      AI.Tools.Plan.call(%{"plan_name" => plan_name, "meta_delta" => new_delta})

      path = Store.Project.Plan.plan_path(store_project, plan_name)
      %{"meta" => meta} = path |> File.read!() |> Jason.decode!()

      assert meta["a"] == 1
      assert meta["b"] == 3
      assert meta["c"] == 4
      assert is_binary(meta["updated_at"])
    end
  end
end