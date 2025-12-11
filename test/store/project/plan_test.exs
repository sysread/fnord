defmodule Store.Project.PlanTest do
  use Fnord.TestCase, async: false

  describe "plan_dir/1 and plan_path/2" do
    test "compute paths under the project store" do
      project = %Store.Project{
        name: "test",
        store_path: "/tmp/fnord-projects/test",
        source_root: "/src/test",
        exclude: [],
        conversation_dir: "/tmp/fnord-projects/test/conversations",
        exclude_cache: nil
      }

      assert Store.Project.Plan.plan_dir(project) == "/tmp/fnord-projects/test/plans"

      assert Store.Project.Plan.plan_path(project, "refactor-scheduler") ==
               "/tmp/fnord-projects/test/plans/refactor-scheduler.json"
    end
  end

  describe "normalize/1" do
    test "defaults missing fields and ignores unknown keys" do
      data = %{
        "meta" => %{"title" => "T"},
        "extra" => %{"foo" => "bar"}
      }

      assert {:ok, %Store.Project.Plan{} = plan} = Store.Project.Plan.normalize(data)
      assert plan.version == 1
      assert plan.meta == %{"title" => "T"}
      assert plan.design == nil
      assert plan.implementation == nil
      assert plan.decisions == []
      assert plan.work_log == []
      assert plan.raw == data
    end

    test "returns error for unsupported version" do
      data = %{"version" => 999}
      assert {:error, :unsupported_version} = Store.Project.Plan.normalize(data)
    end
  end

  describe "read/1 and write/2" do
    test "round trips a plan" do
      plan = %Store.Project.Plan{
        version: 1,
        meta: %{"title" => "Round Trip"},
        design: %{"format" => "markdown", "content" => "# Hi"},
        implementation: %{"milestones" => []},
        decisions: [%{"id" => "dec-1"}],
        work_log: [%{"summary" => "did a thing"}],
        raw: %{}
      }

      contents = ""

      Util.Temp.with_tmp(contents, fn path ->
        assert :ok = Store.Project.Plan.write(path, plan)
        assert {:ok, %Store.Project.Plan{} = decoded} = Store.Project.Plan.read(path)

        assert decoded.version == plan.version
        assert decoded.meta == plan.meta
        assert decoded.design == plan.design
        assert decoded.implementation == plan.implementation
        assert decoded.decisions == plan.decisions
        assert decoded.work_log == plan.work_log
      end)
    end

    test "returns error on invalid JSON" do
      Util.Temp.with_tmp("not-json", fn path ->
        assert {:error, :invalid_json_format} = Store.Project.Plan.read(path)
      end)
    end
  end
end
