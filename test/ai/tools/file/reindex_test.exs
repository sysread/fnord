defmodule AI.Tools.File.ReindexTest do
  use Fnord.TestCase

  alias AI.Tools.File.Reindex

  describe "spec/0" do
    test "returns a function spec with appropriate name, strict flag, and no parameters" do
      spec = Reindex.spec()

      assert spec.type == "function"
      assert spec.function.name == "file_reindex_tool"
      assert spec.function.strict

      params = spec.function.parameters
      assert params.required == []
      assert params.properties == %{}
    end
  end

  describe "read_args/1" do
    test "returns ok and empty map for any input" do
      assert Reindex.read_args(%{}) == {:ok, %{}}
      assert Reindex.read_args(%{"foo" => "bar"}) == {:ok, %{}}
      assert Reindex.read_args("anything") == {:ok, %{}}
      assert Reindex.read_args(nil) == {:ok, %{}}
    end
  end

  describe "call/1" do
    test "invokes Cmd.Index and returns success tuple" do
      assert Reindex.call(%{}) == {:ok, "Full reindex complete"}
    end
  end
end