defmodule Services.NotesTest do
  use Fnord.TestCase, async: false

  alias Services.Notes

  describe "pending ops instrumentation" do
    test "pending_count/0 defaults to 0 and pending?/0 is false" do
      assert Notes.pending_count() == 0
      refute Notes.pending?()
    end

    test "pending_count is clamped to >= 0 even if ETS counter goes negative" do
      # The implementation uses an ETS named table :notes_status.
      # Ensure it exists and then force it negative.
      case :ets.info(:notes_status) do
        :undefined -> :ets.new(:notes_status, [:named_table, :public, read_concurrency: true])
        _ -> :ok
      end

      :ets.insert(:notes_status, {:pending_ops, -5})

      # Any decrement should clamp to 0.
      # We can't call dec_pending/0 directly (private), but we can exercise it by
      # sending a cast that will always call inc_pending/dec_pending around its body.
      Notes.load_notes()
      Notes.join()

      assert Notes.pending_count() == 0
      refute Notes.pending?()
    end
  end

  describe "consolidation no-op path" do
    test "consolidate/0 does not crash and returns pending to 0 when there are no new facts" do
      # AI.Notes.has_new_facts?/0 should typically be false in a fresh test HOME.
      assert Notes.pending_count() == 0
      Notes.consolidate()
      Notes.join()
      assert Notes.pending_count() == 0
    end
  end
end
