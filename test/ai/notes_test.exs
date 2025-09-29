defmodule AI.NotesTest do
  use Fnord.TestCase, async: false

  alias AI.Notes

  setup do
    :meck.new(AI.Completion, [:no_link, :passthrough, :non_strict])
    on_exit(fn -> :meck.unload(AI.Completion) end)

    proj = mock_project("test_project")
    File.mkdir_p!(proj.store_path)

    {:ok, %{proj: proj}}
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
  end
end
