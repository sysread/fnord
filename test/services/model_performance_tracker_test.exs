defmodule Services.ModelPerformanceTracker.Test do
  use Fnord.TestCase

  setup do
    Services.ModelPerformanceTracker.reset_session()
    :ok
  end

  describe "start_session/0" do
    test "returns a new session id and clears any prior data" do
      id1 = Services.ModelPerformanceTracker.start_session()
      id2 = Services.ModelPerformanceTracker.start_session()

      # session IDs are 16-char hex strings and must differ
      assert is_binary(id1) and byte_size(id1) == 16
      assert is_binary(id2) and byte_size(id2) == 16
      refute id1 == id2

      # no completed requests
      assert Services.ModelPerformanceTracker.generate_report() == ""
    end
  end

  describe "begin_tracking/1 and end_tracking/2" do
    test "begin_tracking returns an id and end_tracking moves it to completed" do
      model = AI.Model.fast()
      tid = Services.ModelPerformanceTracker.begin_tracking(model)
      assert is_binary(tid) and byte_size(tid) == 8

      # ensure a measurable duration
      Process.sleep(5)

      :ok =
        Services.ModelPerformanceTracker.end_tracking(
          tid,
          %{prompt_tokens: 5, completion_tokens: 3, reasoning_tokens: 1, total_tokens: 9}
        )

      report = Services.ModelPerformanceTracker.generate_report()
      assert report =~ "Total API Requests: 1"
      assert report =~ "Total Tokens: 9"
    end

    test "end_tracking with unknown id is a no-op and does not crash" do
      :ok = Services.ModelPerformanceTracker.end_tracking("bogus", %{})
      assert Services.ModelPerformanceTracker.generate_report() == ""
    end
  end

  describe "generate_report/0 when no data" do
    test "returns an empty string" do
      assert Services.ModelPerformanceTracker.generate_report() == ""
    end
  end

  describe "generate_report/0 with multiple models and usage maps" do
    test "prints overall summary, by-model breakdown, detailed metrics, and input-analysis buckets" do
      tracker = Services.ModelPerformanceTracker

      usage1 = %{prompt_tokens: 10, completion_tokens: 3, reasoning_tokens: 2, total_tokens: 15}

      usage2 = %{
        "prompt_tokens" => 20,
        "completion_tokens" => 5,
        "reasoning_tokens" => 0,
        "total_tokens" => 25
      }

      usage3 = %{
        prompt_tokens: 5_000,
        completion_tokens: 10,
        reasoning_tokens: 0,
        total_tokens: 5_010
      }

      usage4 = %{
        prompt_tokens: 15_000,
        completion_tokens: 100,
        reasoning_tokens: 50,
        total_tokens: 15_150
      }

      model_a = AI.Model.fast()
      model_b = AI.Model.reasoning(:high)

      for usage <- [usage1, usage2] do
        tid = tracker.begin_tracking(model_a)
        Process.sleep(5)
        :ok = tracker.end_tracking(tid, usage)
      end

      for usage <- [usage3, usage4] do
        tid = tracker.begin_tracking(model_b)
        Process.sleep(5)
        :ok = tracker.end_tracking(tid, usage)
      end

      report = tracker.generate_report()
      refute report == ""

      # Headings and totals
      assert report =~ "### Model Performance Report"
      assert report =~ "Session Summary:"
      assert report =~ "Total API Requests: 4"
      assert report =~ "Total Tokens: 20200"

      # By-model breakdown
      assert report =~ "**By Model:**"
      assert report =~ "- gpt-4.1-nano: 2 requests"
      assert report =~ "- o4-mini (reasoning: high): 2 requests"

      # Detailed sections order
      {pos_a, _} = :binary.match(report, "**gpt-4.1-nano:**")
      {pos_b, _} = :binary.match(report, "**o4-mini (reasoning: high):**")
      assert pos_a < pos_b

      # Bucket analysis appears
      assert report =~ "- Input Size Analysis:"
      assert report =~ "Medium (2-10K):"
      assert report =~ "Large (>10K):"
    end
  end

  describe "reset_session/0" do
    test "clears session so a fresh session starts" do
      tid = Services.ModelPerformanceTracker.begin_tracking(AI.Model.fast())
      Process.sleep(5)

      :ok =
        Services.ModelPerformanceTracker.end_tracking(tid, %{
          prompt_tokens: 1,
          completion_tokens: 1,
          total_tokens: 2
        })

      :ok = Services.ModelPerformanceTracker.reset_session()
      assert Services.ModelPerformanceTracker.generate_report() == ""

      tid2 = Services.ModelPerformanceTracker.begin_tracking(AI.Model.fast())
      refute tid2 == tid
    end
  end
end
