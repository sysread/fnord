defmodule Cmd.AskTest do
  use Fnord.TestCase, async: false

  setup do
    Services.Globals.delete_env(:fnord, :auto_policy)

    # Ensure settings directory exists without deleting it to avoid races
    settings_file = Settings.settings_file()
    settings_dir = Path.dirname(settings_file)
    File.mkdir_p!(settings_dir)

    # Ensure lock directory parent exists so FileLock can create locks without errors
    lock_dir = settings_file <> ".lock"
    lock_parent = Path.dirname(lock_dir)
    File.mkdir_p!(lock_parent)

    :ok
  end

  test "default auto policy is deny after 180_000 ms when no flags provided" do
    opts = %{}
    # Apply the default policy
    assert :ok == apply(Cmd.Ask, :set_auto_policy, [opts])
    assert Settings.get_auto_policy() == {:deny, 180_000}
  end

  test "auto deny override uses provided seconds" do
    opts = %{auto_deny_after: 5}
    # Validate flags first
    assert :ok == apply(Cmd.Ask, :validate_auto, [opts])
    assert :ok == apply(Cmd.Ask, :set_auto_policy, [opts])
    assert Settings.get_auto_policy() == {:deny, 5_000}
  end

  test "auto approve override uses provided seconds" do
    opts = %{auto_approve_after: 2}
    assert :ok == apply(Cmd.Ask, :validate_auto, [opts])
    assert :ok == apply(Cmd.Ask, :set_auto_policy, [opts])
    assert Settings.get_auto_policy() == {:approve, 2_000}
  end

  test "mutually exclusive auto flags returns error" do
    opts = %{auto_approve_after: 1, auto_deny_after: 2}
    assert {:error, _msg} = apply(Cmd.Ask, :validate_auto, [opts])
  end

  test "invalid auto flag values return error" do
    assert {:error, _} = apply(Cmd.Ask, :validate_auto, [%{auto_approve_after: 0}])
    assert {:error, _} = apply(Cmd.Ask, :validate_auto, [%{auto_deny_after: -1}])
  end

  describe "run/3 exception handling" do
    setup do
      # Force exception in Services.Conversation.start_link via :meck
      :meck.new(Services.Conversation, [:passthrough])
      :meck.expect(Services.Conversation, :start_link, fn _args -> raise "boom" end)
      :meck.validate(Services.Conversation)

      on_exit(fn ->
        try do
          :meck.unload(Services.Conversation)
        catch
          _, _ -> :ok
        end
      end)

      :ok
    end

    test "propagates start_link exceptions (outside try)" do
      opts = %{question: "whoops?", rounds: 1}

      assert_raise RuntimeError, "boom", fn ->
        Cmd.Ask.run(opts, [], [])
      end
    end
  end
end
