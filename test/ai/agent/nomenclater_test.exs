defmodule AI.Agent.NomenclaterTest do
  use Fnord.TestCase, async: true
  alias AI.Agent.Nomenclater

  # Nomenclater builds its own completion via AI.Agent.get_completion, so the
  # canned responses below run through the real AI.Completion loop and the
  # tests exercise Nomenclater's JSON extraction against actual loop output.

  test "parses fenced JSON response" do
    fenced = """
    ```json
    {"names":["Zorg","Merv"]}
    ```
    """

    canned_completion(fenced)
    agent = AI.Agent.new(Nomenclater, named?: false)

    assert {:ok, ["Zorg", "Merv"]} =
             Nomenclater.get_response(%{
               agent: agent,
               want: 2,
               used: []
             })
  end

  test "parses prefixed JSON response" do
    canned_completion("Here is the JSON: {\"names\":[\"Lrrr\"]}")
    agent = AI.Agent.new(Nomenclater, named?: false)

    assert {:ok, ["Lrrr"]} =
             Nomenclater.get_response(%{agent: agent, want: 1, used: []})
  end

  test "retries on malformed JSON then succeeds" do
    bad = "no JSON here"
    good = "{\"names\":[\"Alpha\"]}"

    # The stub runs in the test process (Nomenclater is called directly), so
    # a pdict counter distinguishes the first completion from the retry.
    canned_completion(fn _msgs ->
      calls = Process.get(:nomenclater_calls, 0)
      Process.put(:nomenclater_calls, calls + 1)

      case calls do
        0 -> {:ok, :msg, bad, 0}
        _ -> {:ok, :msg, good, 0}
      end
    end)

    agent = AI.Agent.new(Nomenclater, named?: false)

    assert {:ok, ["Alpha"]} =
             Nomenclater.get_response(%{
               agent: agent,
               want: 1,
               used: []
             })
  end

  test "parses epithet-rich name with apostrophe and hyphen" do
    canned_completion("{\"names\":[\"K'tah the Yak-Shaver\"]}")
    agent = AI.Agent.new(Nomenclater, named?: false)

    assert {:ok, ["K'tah the Yak-Shaver"]} =
             Nomenclater.get_response(%{agent: agent, want: 1, used: []})
  end

  describe "response_format schema" do
    setup do
      # The response_format is only visible at the completion-API boundary,
      # so this stubs the mock directly rather than using canned_completion.
      test_pid = self()

      stub(AI.CompletionAPI.Mock, :get, fn _model, _msgs, _tools, rf, _web, _verbosity ->
        send(test_pid, {:captured_response_format, rf})
        {:ok, :msg, ~s/{"names": ["Alpha"]}/, 0}
      end)

      :ok
    end

    test "uses ECMA-262 compatible ASCII pattern" do
      agent = AI.Agent.new(Nomenclater, named?: false)
      used = []
      # Trigger the call which will send us the captured response_format
      assert {:ok, ["Alpha"]} =
               AI.Agent.Nomenclater.get_response(%{agent: agent, want: 1, used: used})

      assert_receive {:captured_response_format, rf}, 1000

      # Dig out pattern
      pattern =
        get_in(rf, ["json_schema", "schema", "properties", "names", "items", "pattern"]) ||
          get_in(rf, [:json_schema, :schema, :properties, :names, :items, :pattern])

      assert is_binary(pattern)
      assert pattern == "^[A-Za-z0-9][A-Za-z0-9\\s'’\\-.,!/:()]*$"
      refute String.contains?(pattern, "\\p{L}")
      refute String.contains?(pattern, "\\p{N}")
    end
  end
end
