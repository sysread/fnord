defmodule AI.Agent.Code.CommonCommitMessagePromptTest do
  use ExUnit.Case, async: true

  alias AI.Agent.Code.Common

  describe "commit_message_style_prompt/0" do
    test "contains key wrapping rules and a max line length of 120" do
      prompt = Common.commit_message_style_prompt()
      # must mention the hard cap
      assert String.contains?(prompt, "120"), "Prompt should reference '120' characters max"
      # must mention mimicking nearby commits
      assert String.contains?(prompt, "Mimic"), "Prompt should instruct to mimic nearby commit style"
      # must warn not to reflow code blocks
      assert String.contains?(prompt, "code blocks"), "Prompt should mention not reflowing code blocks"
    end
  end
end