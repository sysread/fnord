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
end
