defmodule Services.Approvals.Shell.PersistentApproval.Test do
  use Fnord.TestCase, async: false

  describe "customize/2" do
    test "skips prompting for approved prefixes" do
      state = %{session: [{:prefix, "foo"}]}

      stages = [
        {"foo", "foo"},
        {"foo", "foo"}
      ]

      assert Services.Approvals.Shell.customize(state, stages) == {:approved, state}
    end

    test "prompts and adds unapproved prefixes to session" do
      initial_state = %{session: [{:prefix, "foo"}]}

      stages = [
        {"foo", "foo"},
        {"bar", "bar"},
        {"bar", "bar"}
      ]

      :ok = :meck.new(UI, [:passthrough])

      on_exit(fn ->
        try do
          :meck.unload(UI)
        catch
          _, _ -> :ok
        end
      end)

      :meck.expect(UI, :choose, fn
        prompt, _opts ->
          assert String.contains?(prompt, "Choose approval scope for: bar")
          "Approve for this session"
      end)

      :meck.expect(UI, :prompt, fn _ -> "" end)
      {:approved, result_state} = Services.Approvals.Shell.customize(initial_state, stages)

      assert result_state.session == [
               {:prefix, "foo"},
               {:prefix, "bar"}
             ]
    end
  end
end
