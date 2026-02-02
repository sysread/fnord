defmodule Services.Task.ListTest do
  use Fnord.TestCase, async: true

  describe "new/2" do
    test "creates with id and nil description" do
      list = Services.Task.List.new("list1")
      assert %Services.Task.List{id: "list1", description: nil, tasks: []} = list
    end

    test "creates with id and description" do
      list = Services.Task.List.new("list2", "A description")
      assert list.id == "list2"
      assert list.description == "A description"
      assert list.tasks == []
    end
  end

  describe "add/2" do
    test "adds tasks to the end of the list" do
      list = Services.Task.List.new("x")
      task1 = %{id: "t1", outcome: :todo}
      task2 = %{id: "t2", outcome: :done, result: "ok"}
      list = Services.Task.List.add(list, task1)
      assert list.tasks == [task1]
      list = Services.Task.List.add(list, task2)
      assert list.tasks == [task1, task2]
    end
  end

  describe "push/2" do
    test "pushes tasks to the front of the list" do
      list = Services.Task.List.new("x")
      task1 = %{id: "t1", outcome: :todo}
      task2 = %{id: "t2", outcome: :todo}
      list = Services.Task.List.push(list, task1)
      assert list.tasks == [task1]
      list = Services.Task.List.push(list, task2)
      assert list.tasks == [task2, task1]
    end
  end

  describe "resolve/4" do
    test "resolves only todo tasks with matching id" do
      t1 = %{id: "a", outcome: :todo, result: nil}
      t2 = %{id: "b", outcome: :todo, result: nil}
      t3 = %{id: "a", outcome: :done, result: "old"}
      list = Services.Task.List.new("list", "desc")
      list = list |> Services.Task.List.add(t1) |> Services.Task.List.add(t2) |> Services.Task.List.add(t3)
      resolved = Services.Task.List.resolve(list, "a", :done, "ok")

      [r1, r2, r3] = resolved.tasks
      assert r1.outcome == :done and r1.result == "ok"
      assert r2 == t2
      assert r3 == t3
    end
  end

  describe "to_string/2" do
    test "renders without description and without detail" do
      t1 = %{id: "a", outcome: :todo}
      t2 = %{id: "b", outcome: :done, result: "res"}
      list = Services.Task.List.new("id") |> Services.Task.List.add(t1) |> Services.Task.List.add(t2)

      expected =
        [
          "Task List id:",
          "[ ] a",
          "[✓] b"
        ]
        |> Enum.join("\n")

      assert Services.Task.List.to_string(list) == expected
    end

    test "renders with description and with detail" do
      t1 = %{id: "a", outcome: :done, result: "res"}
      t2 = %{id: "b", outcome: :failed, result: "err"}
      list = Services.Task.List.new("id", "desc") |> Services.Task.List.add(t1) |> Services.Task.List.add(t2)

      expected =
        [
          "Task List id: desc",
          "[✓] a: res",
          "[✗] b: err"
        ]
        |> Enum.join("\n")

      assert Services.Task.List.to_string(list, true) == expected
    end
  end
end
