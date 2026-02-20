defmodule AI.Agent.Coordinator.TaskSummaryTest do
  use Fnord.TestCase

  test "task_summary formats realistic permutations of lists and tasks" do
    mock_project("coordinator_summary")
    ctx = mock_conversation()
    convo = ctx.conversation_pid

    # Done list: all tasks completed
    done_list = Services.Task.start_list()
    Services.Task.add_task(done_list, "done1", "do this")
    Services.Task.add_task(done_list, "done2", "do that")
    Services.Task.complete_task(done_list, "done1", "ok1")
    Services.Task.complete_task(done_list, "done2", "ok2")
    # ensure conversation persisted
    Services.Conversation.upsert_task_list(convo, done_list, Services.Task.get_list(done_list))

    # In-progress list: some terminal tasks, at least one todo remains
    in_list = Services.Task.start_list()
    Services.Task.add_task(in_list, "in1", "step 1")
    Services.Task.add_task(in_list, "in2", "step 2")
    Services.Task.add_task(in_list, "in3", "step 3")
    Services.Task.complete_task(in_list, "in1", "res1")
    Services.Task.fail_task(in_list, "in2", "err2")
    # ensure conversation persisted
    Services.Conversation.upsert_task_list(convo, in_list, Services.Task.get_list(in_list))
    # in3 remains todo -> list should be in-progress

    # Planning list: tasks created but no terminal outcomes
    plan_list = Services.Task.start_list()
    Services.Task.add_task(plan_list, "pl1", "plan 1")
    Services.Task.add_task(plan_list, "pl2", "plan 2")
    Services.Conversation.upsert_task_list(convo, plan_list, Services.Task.get_list(plan_list))

    summary = AI.Agent.Coordinator.Tasks.task_summary(convo)

    # Assertions for done list (individual tasks NOT shown)
    assert summary =~ "## #{done_list} :: Complete"
    refute summary =~ "done1"
    refute summary =~ "done2"

    # Assertions for in-progress list
    assert summary =~ "## #{in_list} :: In Progress"
    assert summary =~ "- [✓] in1: res1"
    assert summary =~ "- [✗] in2: err2"
    assert summary =~ "- [ ] in3"

    # Assertions for planning list
    assert summary =~ "## #{plan_list} :: Planning"
    assert summary =~ "- [ ] pl1"
    assert summary =~ "- [ ] pl2"
  end
end
