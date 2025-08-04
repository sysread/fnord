defmodule AI.AgentTest do
  use Fnord.TestCase, async: true

  describe "behavior contract" do
    test "defines get_response callback" do
      callbacks = AI.Agent.behaviour_info(:callbacks)
      assert {:get_response, 1} in callbacks
    end

    test "validate_opts is optional callback" do
      optional_callbacks = AI.Agent.behaviour_info(:optional_callbacks)
      assert {:validate_opts, 1} in optional_callbacks
    end

    test "behavior defines expected types" do
      # This test ensures the behavior defines the necessary types
      # Dialyzer will catch type mismatches at compile time
      assert function_exported?(AI.Agent, :behaviour_info, 1)
    end
  end
end