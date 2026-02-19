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

    summary = AI.Agent.Coordinator.task_summary(convo)

    # Assertions for done list
    assert summary =~ "- Task List #{done_list}: [✓] completed"
    assert summary =~ "  - done1: [✓] done (ok1)"
    assert summary =~ "  - done2: [✓] done (ok2)"

    # Assertions for in-progress list
    assert summary =~ "- Task List #{in_list}: [ ] in progress"
    assert summary =~ "  - in1: [✓] done (res1)"
    assert summary =~ "  - in2: [✗] failed (err2)"
    assert summary =~ "  - in3: [ ] todo"

    # Assertions for planning list
    assert summary =~ "- Task List #{plan_list}: [ ] planning"
    assert summary =~ "  - pl1: [ ] todo"
    assert summary =~ "  - pl2: [ ] todo"
  end
end
