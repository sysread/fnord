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

    test "merges meta_delta and preserves unrelated keys for existing plan", %{
      store_project: store_project
    } do
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

  describe "call/1 with design_content" do
    setup do
      project = mock_project("plan_test_project")
      {:ok, store_project} = Store.get_project("plan_test_project")
      %{project: project, store_project: store_project}
    end

    test "creates new plan file when design_content is provided for missing plan", %{
      store_project: store_project
    } do
      plan_name = "new_design_plan"
      design_content = %{"layout" => ["header", "footer"]}

      AI.Tools.Plan.call(%{"plan_name" => plan_name, "design_content" => design_content})

      path = Store.Project.Plan.plan_path(store_project, plan_name)
      assert File.exists?(path)

      %{"meta" => meta, "design" => design} = path |> File.read!() |> Jason.decode!()
      assert design["content"] == design_content
      assert design["format"] == "markdown"
      assert is_binary(meta["updated_at"])
    end

    test "replaces design_content cleanly and preserves other sections", %{
      store_project: store_project
    } do
      plan_name = "new_design_plan"
      initial_design = %{"layout" => ["intro"]}
      AI.Tools.Plan.call(%{"plan_name" => plan_name, "design_content" => initial_design})
      path = Store.Project.Plan.plan_path(store_project, plan_name)
      %{"meta" => first_meta} = path |> File.read!() |> Jason.decode!()
      first_updated = first_meta["updated_at"]
      :timer.sleep(1)
      updated_design = %{"layout" => ["updated"]}
      AI.Tools.Plan.call(%{"plan_name" => plan_name, "design_content" => updated_design})

      %{"meta" => meta, "design" => design} = path |> File.read!() |> Jason.decode!()
      assert design["content"] == updated_design
      assert design["format"] == "markdown"
      assert is_binary(meta["updated_at"])
      assert meta["updated_at"] != first_updated
      assert meta["updated_at"] != first_updated
    end
  end

  describe "call/1 with implementation" do
    setup do
      project = mock_project("plan_test_project")
      {:ok, store_project} = Store.get_project("plan_test_project")
      %{project: project, store_project: store_project}
    end

    test "stores valid implementation with milestones", %{store_project: store_project} do
      plan_name = "implementation_plan"

      implementation = %{
        "milestones" => [
          %{
            "id" => "ms-1",
            "title" => "Introduce FooBus",
            "status" => "planned",
            "steps" => ["Create module", "Add tests"]
          }
        ]
      }

      AI.Tools.Plan.call(%{"plan_name" => plan_name, "implementation" => implementation})

      path = Store.Project.Plan.plan_path(store_project, plan_name)
      assert File.exists?(path)

      %{"meta" => meta, "implementation" => impl} = path |> File.read!() |> Jason.decode!()
      assert impl == implementation
      assert is_binary(meta["updated_at"])
    end

    test "rejects malformed implementation without milestones", %{store_project: store_project} do
      plan_name = "bad_implementation_plan"
      malformed_impl = %{"details" => "missing milestones"}

      AI.Tools.Plan.call(%{"plan_name" => plan_name, "implementation" => malformed_impl})

      path = Store.Project.Plan.plan_path(store_project, plan_name)
      refute File.exists?(path)
    end
  end
end
