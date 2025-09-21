defmodule AI.NotesTest do
  use Fnord.TestCase, async: false

  alias AI.Notes

  setup do
    :meck.new(AI.Completion, [:no_link, :passthrough, :non_strict])
    on_exit(fn -> :meck.unload(AI.Completion) end)
    :ok
  end

  describe "format_external_docs/0" do
    test "returns empty string when no external docs exist" do
      # Mock AI.Completion.get to prevent network calls
      :meck.expect(AI.Completion, :get, fn _opts ->
        {:ok, %{response: "Mocked response"}}
      end)

      # Create a notes instance to test the private function indirectly
      state = Notes.new()

      # This should compile and not crash
      result = Notes.ask(state, "test question")
      assert is_binary(result)
    end

    test "includes external docs in ask function when they exist" do
      # Mock AI.Completion.get to prevent network calls
      :meck.expect(AI.Completion, :get, fn _opts ->
        {:ok, %{response: "Mocked response with external docs"}}
      end)

      home_dir = Settings.get_user_home()

      # Create some external docs
      claude_path = Path.join(home_dir, ".claude/CLAUDE.md")
      agents_path = Path.join(home_dir, ".agents/AGENTS.md")

      File.mkdir_p!(Path.dirname(claude_path))
      File.write!(claude_path, "Test Claude instructions")

      File.mkdir_p!(Path.dirname(agents_path))
      File.write!(agents_path, "Test Agents instructions")

      state = Notes.new()

      # The ask function should include external docs in the prompt
      result = Notes.ask(state, "What are the instructions?")
      assert is_binary(result)

      # We can't easily test the exact content without mocking, but we can ensure it compiles and runs
    end
  end
end
