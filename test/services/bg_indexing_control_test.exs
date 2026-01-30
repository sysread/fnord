defmodule Services.BgIndexingControlTest do
  use Fnord.TestCase, async: false

  alias Services.BgIndexingControl

  @model "test-model"

  setup do
    # Verify BgIndexingControl correctness/idempotency; ensure it no longer relies on Services.Once

    # Ensure we don't inherit any previous state from other tests.
    Services.Globals.delete_env(:fnord, :bg_indexer_paused_models)
    Services.Globals.delete_env(:fnord, :bg_indexer_throttle_counts)
    Services.Globals.delete_env(:fnord, :bg_indexer_throttle_threshold)

    on_exit(fn ->
      Services.Globals.delete_env(:fnord, :bg_indexer_paused_models)
      Services.Globals.delete_env(:fnord, :bg_indexer_throttle_counts)
      Services.Globals.delete_env(:fnord, :bg_indexer_throttle_threshold)
    end)

    :ok
  end

  test "ensure_init/0 seeds defaults without Services.Once" do
    assert :ok == BgIndexingControl.ensure_init()

    assert false == BgIndexingControl.paused?(@model)
    assert 3 == BgIndexingControl.threshold()
  end

  test "ensure_init/0 is idempotent and does not clobber existing threshold" do
    assert :ok == BgIndexingControl.ensure_init()
    assert :ok == BgIndexingControl.set_threshold(7)
    assert 7 == BgIndexingControl.threshold()

    assert :ok == BgIndexingControl.ensure_init()
    assert 7 == BgIndexingControl.threshold()
  end

  test "note_throttle/1 pauses the model when threshold is reached" do
    BgIndexingControl.set_threshold(2)

    assert false == BgIndexingControl.paused?(@model)
    assert :ok == BgIndexingControl.note_throttle(@model)
    assert false == BgIndexingControl.paused?(@model)

    assert :ok == BgIndexingControl.note_throttle(@model)
    assert true == BgIndexingControl.paused?(@model)
  end
end
