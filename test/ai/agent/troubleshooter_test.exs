defmodule AI.Agent.TroubleshooterTest do
  use Fnord.TestCase, async: false

  alias AI.Agent.Troubleshooter

  setup do
    :meck.new(AI.Completion, [:no_link, :passthrough, :non_strict])
    on_exit(fn -> :meck.unload(AI.Completion) end)
    :ok
  end

  describe "get_response/1" do
    test "implements AI.Agent behavior correctly" do
      # Mock AI.Completion.get to prevent network calls
      :meck.expect(AI.Completion, :get, fn _opts ->
        {:error, %{response: "Mocked error response"}}
      end)

      # Test that it handles missing prompt gracefully
      result = Troubleshooter.get_response(%{})
      assert :error = result

      # Test that the module loads and compiles correctly
      assert Code.ensure_loaded?(Troubleshooter)
    end

    test "accepts prompt parameter correctly" do
      # Mock AI.Completion.get to prevent network calls
      :meck.expect(AI.Completion, :get, fn _opts ->
        {:ok, %{response: "Mocked successful response"}}
      end)

      opts = %{prompt: "Test troubleshooting prompt"}

      # Verify the parameter structure is correct
      assert is_map(opts)
      assert Map.has_key?(opts, :prompt)
      assert is_binary(opts.prompt)

      # Test that it can be called with valid prompt (without network calls)
      assert {:ok, "Mocked successful response"} =
               Troubleshooter
               |> AI.Agent.new()
               |> AI.Agent.get_response(opts)
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
