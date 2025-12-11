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

  describe "call/1 with decision_* args" do
    setup do
      project = mock_project("plan_test_project")
      {:ok, store_project} = Store.get_project("plan_test_project")
      %{project: project, store_project: store_project}
    end

    test "appends a single decision entry correctly using decision_* args", %{
      store_project: store_project
    } do
      plan_name = "decision_plan"
      context = "some context"
      change = %{"key" => "value"}
      reason = "test reason"
      affected = ["item1", "item2"]

      AI.Tools.Plan.call(%{
        "plan_name" => plan_name,
        "decision_context" => context,
        "decision_change" => change,
        "decision_reason" => reason,
        "decision_affected" => affected
      })

      path = Store.Project.Plan.plan_path(store_project, plan_name)
      assert File.exists?(path)

      %{"meta" => meta, "decisions" => decisions} =
        path |> File.read!() |> Jason.decode!()

      assert length(decisions) == 1
      [entry] = decisions
      assert is_binary(entry["id"])
      assert is_binary(entry["timestamp"])
      assert entry["context"] == context
      assert entry["change"] == change
      assert entry["reason"] == reason
      assert entry["affected"] == affected
      assert is_binary(meta["updated_at"])
    end

    test "appends multiple decision entries with correct ids", %{store_project: store_project} do
      plan_name = "decision_plan_ids"

      args = %{
        "plan_name" => plan_name,
        "decision_context" => "First decision",
        "decision_change" => %{},
        "decision_reason" => "R1"
      }

      AI.Tools.Plan.call(args)
      AI.Tools.Plan.call(Map.put(args, "decision_context", "Second decision"))

      path = Store.Project.Plan.plan_path(store_project, plan_name)
      %{"decisions" => decisions} = path |> File.read!() |> Jason.decode!()

      assert Enum.map(decisions, & &1["id"]) == ["dec-1", "dec-2"]
    end
  end

  describe "call/1 with work_* args" do
    setup do
      project = mock_project("plan_test_project")
      {:ok, store_project} = Store.get_project("plan_test_project")
      %{project: project, store_project: store_project}
    end

    test "appends a single work log entry correctly using work_* args", %{
      store_project: store_project
    } do
      plan_name = "work_plan"
      summary = "some summary"
      detail = "details of work"
      milestone_id = "ms-1"

      AI.Tools.Plan.call(%{
        "plan_name" => plan_name,
        "work_summary" => summary,
        "work_detail" => detail,
        "work_milestone_id" => milestone_id
      })

      path = Store.Project.Plan.plan_path(store_project, plan_name)
      assert File.exists?(path)

      %{"meta" => meta, "work_log" => work_log} =
        path |> File.read!() |> Jason.decode!()

      assert length(work_log) == 1
      [entry] = work_log
      assert is_binary(entry["id"])
      assert is_binary(entry["timestamp"])
      assert entry["summary"] == summary
      assert entry["detail"] == detail
      assert entry["milestone_id"] == milestone_id
      assert is_binary(meta["updated_at"])
    end

    test "appends multiple work log entries with correct ids", %{store_project: store_project} do
      plan_name = "work_plan_ids"

      args = %{
        "plan_name" => plan_name,
        "work_summary" => "First work"
      }

      AI.Tools.Plan.call(args)
      AI.Tools.Plan.call(Map.put(args, "work_summary", "Second work"))

      path = Store.Project.Plan.plan_path(store_project, plan_name)
      %{"work_log" => work_log} = path |> File.read!() |> Jason.decode!()

      assert Enum.map(work_log, & &1["id"]) == ["work-1", "work-2"]
    end
  end
end
