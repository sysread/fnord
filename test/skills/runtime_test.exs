defmodule Skills.RuntimeTest do
  use Fnord.TestCase, async: false

  describe "model_from_string/1" do
    test "supports known presets" do
      assert {:ok, %AI.Model{}} = Skills.Runtime.model_from_string("smart")
      assert {:ok, %AI.Model{}} = Skills.Runtime.model_from_string("balanced")
      assert {:ok, %AI.Model{}} = Skills.Runtime.model_from_string("fast")
      assert {:ok, %AI.Model{}} = Skills.Runtime.model_from_string("web")
      assert {:ok, %AI.Model{}} = Skills.Runtime.model_from_string("large_context")
      assert {:ok, %AI.Model{}} = Skills.Runtime.model_from_string("large_context:fast")
    end

    test "errors on unknown presets" do
      assert {:error, {:unknown_model_preset, "nope"}} = Skills.Runtime.model_from_string("nope")
    end
  end

  describe "validate_response_format/1" do
    test "accepts nil" do
      assert {:ok, nil} = Skills.Runtime.validate_response_format(nil)
    end

    test "requires a type key" do
      assert {:error, {:missing_response_format_type, _}} =
               Skills.Runtime.validate_response_format(%{"foo" => "bar"})

      assert {:ok, %{"type" => "text"}} =
               Skills.Runtime.validate_response_format(%{"type" => "text"})
    end
  end

  describe "toolbox_from_tags/1" do
    test "errors on unknown tags" do
      assert {:error, {:unknown_tool_tag, "foo"}} =
               Skills.Runtime.toolbox_from_tags(["foo"])
    end

    test "errors when basic is missing" do
      assert {:error, {:missing_basic_tool_tag, ["web"]}} =
               Skills.Runtime.toolbox_from_tags(["web"])
    end
  end
end
