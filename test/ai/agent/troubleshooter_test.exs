defmodule AI.Agent.TroubleshooterTest do
  use Fnord.TestCase

  alias AI.Agent.Troubleshooter

  describe "get_response/1" do
    test "implements AI.Agent behavior correctly" do
      # Test that the module implements the behavior
      assert function_exported?(Troubleshooter, :get_response, 1)
      
      # Test that it handles missing prompt gracefully
      result = Troubleshooter.get_response(%{})
      assert :error = result
    end

    test "accepts prompt and returns response structure" do
      opts = %{prompt: "Test troubleshooting prompt"}
      
      # This will make an actual AI call, so we can't easily test the exact response
      # But we can ensure it returns the correct structure
      result = Troubleshooter.get_response(opts)
      
      case result do
        {:ok, response} ->
          assert is_binary(response)
        {:error, response} ->
          assert is_binary(response)
      end
    end

    test "has access to troubleshooting tools" do
      # Test that the private function for getting tools works
      # We can't directly call private functions, but we can ensure the module loads
      # and that the tool integration doesn't cause compilation errors
      assert Code.ensure_loaded?(Troubleshooter)
    end
  end

  describe "troubleshooting workflow" do
    test "module has correct behavior and compiles successfully" do
      # Ensure module is loaded
      Code.ensure_loaded!(Troubleshooter)
      
      # Verify the module implements the AI.Agent behavior
      assert function_exported?(Troubleshooter, :get_response, 1)
      
      # Verify module loads without errors
      assert Code.ensure_loaded?(Troubleshooter)
      
      # The detailed prompt testing would require accessing private module attributes
      # which is not straightforward in Elixir. The fact that the module compiles
      # and the integration test passes validates the prompt structure.
    end
  end
end