defmodule Memory.IngestionTest do
  use Fnord.TestCase, async: false

  setup do
    {:ok, project: mock_project("memory_ingestion_test")}
  end

  describe "ingest_all_conversations/0" do
    test "skips the current conversation" do
      # Start a real conversation service so :current_conversation is set and
      # Services.Conversation.get_id/1 works.
      _conv_ctx = mock_conversation()

      :meck.new(Memory, [:no_link, :passthrough, :non_strict])

      # If ingest_all_conversations accidentally tries to ingest the current
      # conversation, this will be called (and the test will fail).
      :meck.expect(Memory, :ingest_conversation, fn _conversation ->
        flunk("ingest_conversation/1 should not be called for current conversation")
      end)

      assert :ok = Memory.ingest_all_conversations()

      :meck.unload(Memory)
    end
  end

  describe "ingest_conversation/1" do
    setup do
      :meck.new(AI.CompletionAPI, [:no_link, :passthrough, :non_strict])

      on_exit(fn ->
        :meck.unload(AI.CompletionAPI)
      end)

      :ok
    end

    test "skips ingestion when long_term_memory_hash matches" do
      msgs = [AI.Util.user_msg("hello")]
      hash = msgs |> Jason.encode!() |> :erlang.md5() |> Base.encode16()

      conv = Store.Project.Conversation.new()

      assert {:ok, _} =
               Store.Project.Conversation.write(conv, %{
                 messages: msgs,
                 metadata: %{long_term_memory_hash: hash},
                 memory: []
               })

      # Any call to the API would mean we did not skip.
      :meck.expect(AI.CompletionAPI, :get, fn _model, _msgs, _specs, _res_fmt, _web_search? ->
        flunk("AI.CompletionAPI.get/5 should not be called when hash matches")
      end)

      assert :ok = Memory.ingest_conversation(conv)
    end

    test "ingests and writes long_term_memory_hash when conversation changed" do
      msgs = [AI.Util.user_msg("hello")]

      conv = Store.Project.Conversation.new()

      assert {:ok, _} =
               Store.Project.Conversation.write(conv, %{
                 messages: msgs,
                 metadata: %{},
                 memory: []
               })

      # Fake completion response from the ingestion agent.
      :meck.expect(AI.CompletionAPI, :get, fn _model, _msgs, _specs, _res_fmt, _web_search? ->
        {:ok, :msg, "Learned a thing.", 0}
      end)

      assert :ok = Memory.ingest_conversation(conv)

      {:ok, %{metadata: meta}} = Store.Project.Conversation.read(conv)

      new_hash = msgs |> Jason.encode!() |> :erlang.md5() |> Base.encode16()
      assert meta.long_term_memory_hash == new_hash
    end
  end
end
