defmodule AI.Agent.NomenclaterTest do
  use Fnord.TestCase, async: false
  alias AI.Agent.Nomenclater

  setup do
    # Create a Meck mock for AI.Agent to intercept get_completion calls,
    # allowing existing functions to passthrough
    # Mock AI.Agent: allow real functions to passthrough except for get_completion
    :ok = :meck.new(AI.Agent, [:no_link, :passthrough, :non_strict])

    on_exit(fn ->
      # Unload Meck mock
      :meck.unload(AI.Agent)
    end)

    :ok
  end

  test "parses fenced JSON response" do
    fenced = """
    ```json
    {"names":["Zorg","Merv"]}
    ```
    """

    :meck.expect(AI.Agent, :get_completion, fn _, _ -> {:ok, %{response: fenced}} end)
    agent = AI.Agent.new(Nomenclater, named?: false)

    assert {:ok, ["Zorg", "Merv"]} =
             Nomenclater.get_response(%{
               agent: agent,
               want: 2,
               used: []
             })
  end

  test "parses prefixed JSON response" do
    prefixed = "Here is the JSON: {\"names\":[\"Lrrr\"]}"
    :meck.expect(AI.Agent, :get_completion, fn _, _ -> {:ok, %{response: prefixed}} end)
    agent = AI.Agent.new(Nomenclater, named?: false)

    assert {:ok, ["Lrrr"]} =
             Nomenclater.get_response(%{agent: agent, want: 1, used: []})
  end

  test "retries on malformed JSON then succeeds" do
    bad = "no JSON here"
    good = "{\"names\":[\"Alpha\"]}"
    counter = :atomics.new(1, signed: false)

    :meck.expect(AI.Agent, :get_completion, fn _, _ ->
      case :atomics.add_get(counter, 1, 1) do
        1 -> {:ok, %{response: bad}}
        _ -> {:ok, %{response: good}}
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
end
