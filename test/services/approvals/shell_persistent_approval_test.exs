defmodule Services.Approvals.Shell.PersistentApprovalTest do
  use Fnord.TestCase, async: false

  describe "pending_prefixes/2" do
    test "returns unique unapproved prefixes" do
      state = %{session: ["foo"]}
      stages = ["foo", "bar", "foo", "baz", "bar"]

      assert Services.Approvals.Shell.pending_prefixes(state, stages) == ["bar", "baz"]
    end

    test "returns empty list when no stages provided" do
      state = %{session: []}
      stages = []

      assert Services.Approvals.Shell.pending_prefixes(state, stages) == []
    end

    test "returns empty list when all stages approved" do
      state = %{session: ["foo", "bar"]}
      stages = ["foo", "bar", "foo"]

      assert Services.Approvals.Shell.pending_prefixes(state, stages) == []
    end
  end

  describe "customize/2" do
    test "skips prompting for approved prefixes" do
      state = %{session: ["foo"]}
      stages = ["foo", "foo"]

      assert Services.Approvals.Shell.customize(state, stages) == {:approved, state}
    end

    test "prompts and adds unapproved prefixes to session" do
      initial_state = %{session: ["foo"]}
      stages = ["foo", "bar", "bar"]

      :ok = :meck.new(UI, [:passthrough])

      on_exit(fn ->
        try do
          :meck.unload(UI)
        catch
          _, _ -> :ok
        end
      end)

      :meck.expect(UI, :choose, fn
        "Choose approval scope for: bar", _opts -> "Approve for this session"
      end)

      {:approved, result_state} = Services.Approvals.Shell.customize(initial_state, stages)

      assert result_state.session == ["foo", "bar"]
    end
  end
end
