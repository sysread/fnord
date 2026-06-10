defmodule Services.Approvals.Shell.PersistentApprovalTest do
  use Fnord.TestCase, async: true

  setup do
    # Interactive-terminal posture: UI.choose/prompt gate on is_tty?() and
    # !quiet?() before reaching UI.Output. The old UI meck bypassed the gate.
    set_config(:is_tty, true)
    set_config(:quiet, false)
    :ok
  end

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

      stub(UI.Output.Mock, :choose, fn
        "Choose approval scope for:\n    bar\n", _opts ->
          "Approve for this session"
      end)

      stub(UI.Output.Mock, :prompt, fn _msg, _opts -> "" end)
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
        {"git reflog", "git reflog --all"},
        {"git not-preapproved", "git not-preapproved --all"}
      ]

      # Stub prompt to accept default prefix
      stub(UI.Output.Mock, :prompt, fn _msg, _opts -> "" end)
      # Expect only one choose call for the shared prefix
      stub(UI.Output.Mock, :choose, fn
        "Choose approval scope for:\n    git not-preapproved\n", _opts ->
          "Approve for this session"
      end)

      {:approved, result_state} = Services.Approvals.Shell.customize(initial_state, stages)

      # Session should contain exactly one entry for the prompted prefix
      assert result_state.session == [
               {:prefix, "git not-preapproved"}
             ]
    end
  end
end
