defmodule AI.Agent.Coordinator.TemplateTest do
  use Fnord.TestCase, async: false

  @commit_message_snippet "Provide a brief suggestion for a short commit message"

  setup do
    set_log_level(:none)
    :ok
  end

  test "coordinator base template excludes commit-message instruction in non-edit mode" do
    template = AI.Agent.Coordinator.template(%AI.Agent.Coordinator{edit?: false})
    refute String.contains?(template, @commit_message_snippet)
  end

  test "coordinator template includes commit-message instruction in edit mode" do
    template = AI.Agent.Coordinator.template(%AI.Agent.Coordinator{edit?: true})
    assert String.contains?(template, @commit_message_snippet)
  end

  test "coordinator template defaults to base when edit? missing" do
    template = AI.Agent.Coordinator.template(%{})
    refute String.contains?(template, @commit_message_snippet)
  end
end
