defmodule Services.Approvals.Shell.PersistentApprovalTest do
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
        "Choose approval scope for:\n    bar\n", _opts ->
          "Approve for this session"
      end)

      :meck.expect(UI, :prompt, fn _ -> "" end)
      {:approved, result_state} = Services.Approvals.Shell.customize(initial_state, stages)

      assert result_state.session == [
               {:prefix, "foo"},
               {:prefix, "bar"}
             ]
    end

    test "prompts only once for duplicate prefixes with different full strings" do
      initial_state = %{session: []}

      stages = [
        {"git reflog", "git reflog --date=relative"},
        {"git reflog", "git reflog --all"}
      ]

      :ok = :meck.new(UI, [:passthrough])

      on_exit(fn ->
        try do
          :meck.unload(UI)
        catch
          _, _ -> :ok
        end
      end)

      # Stub prompt to accept default prefix
      :meck.expect(UI, :prompt, fn _ -> "" end)
      # Expect only one choose call for the shared prefix
      :meck.expect(UI, :choose, fn
        "Choose approval scope for:\n    git reflog\n", _opts ->
          "Approve for this session"
      end)

      {:approved, result_state} = Services.Approvals.Shell.customize(initial_state, stages)

      # Session should contain exactly one entry for the prefix
      assert result_state.session == [
               {:prefix, "git reflog"}
             ]
    end
  end
end
