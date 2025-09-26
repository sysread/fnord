defmodule AI.Tools.File.ListTest do
  use Fnord.TestCase

  describe "metadata" do
    test "async?/0 returns true" do
      assert AI.Tools.File.List.async?() == true
    end

    test "is_available?/0 returns a boolean (smoke)" do
      assert is_boolean(AI.Tools.File.List.is_available?())
    end

    test "read_args/1 returns {:ok, args}" do
      args = %{"foo" => "bar"}
      assert AI.Tools.File.List.read_args(args) == {:ok, args}
    end

    test "spec/0 returns function spec with no required params" do
      spec = AI.Tools.File.List.spec()
      assert is_map(spec)
      assert spec.type == "function"
      assert spec.function.name == "file_list_tool"
      params = spec.function.parameters
      assert params.required == []
      assert params.properties == %{}
    end
  end

  describe "ui notes" do
    test "ui_note_on_request/1 returns a simple message" do
      assert AI.Tools.File.List.ui_note_on_request(%{}) == "Listing files in project"
    end

    test "ui_note_on_result/2 returns nil" do
      assert AI.Tools.File.List.ui_note_on_result(%{}, :ok) == nil
    end
  end

  describe "call/1 happy path" do
    setup do
      # Create a real mock project and files using Fnord.TestCase helpers
      project = mock_project("list_target")
      # Create files out of order; List should sort them by rel_path
      mock_source_file(project, "b.ex", "# b")
      mock_source_file(project, "a.ex", "# a")
      mock_source_file(project, "c.ex", "# c")

      {:ok, project: project}
    end

    test "returns header and sorted newline-joined rel_path list", %{project: _project} do
      {:ok, out} = AI.Tools.File.List.call(%{})
      assert String.starts_with?(out, "[file_list_tool]\n")
      # After header, expect sorted order: a.ex, b.ex, c.ex
      [_header | lines] = String.split(out, "\n", trim: true)
      assert Enum.join(lines, "\n") == "a.ex\nb.ex\nc.ex"
    end
  end
end
