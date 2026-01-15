defmodule AI.Tools.File.NotesTest do
  use Fnord.TestCase, async: false

  alias AI.Tools.File.Notes

  describe "read_args/1" do
    test "accepts file" do
      assert {:ok, %{"file" => "/abs/path.ex"}} = Notes.read_args(%{"file" => "/abs/path.ex"})
    end

    test "accepts file_path (back-compat)" do
      assert {:ok, %{"file" => "/abs/path.ex"}} =
               Notes.read_args(%{"file_path" => "/abs/path.ex"})
    end

    test "errors when missing file" do
      assert {:error, :missing_argument, "file"} = Notes.read_args(%{})
    end
  end

  describe "call/1" do
    test "returns missing required parameter message when file not present" do
      assert {:error, "Missing required parameter: file."} = Notes.call(%{})
    end

    test "returns user-friendly message when project is not indexed" do
      # Fnord.TestCase sets up a HOME, but project may not be selected at all.
      # Today, AI.Tools.File.Notes.call/1 should return a friendly error (not crash)
      # when the project is not set / not indexed.
      assert {:error, msg} = Notes.call(%{"file" => "/does/not/matter.ex"})
      assert msg =~ "not yet been indexed"
    end
  end
end
