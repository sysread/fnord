defmodule AI.Endpoint.VeniceTest do
  @moduledoc """
  Tests for the Venice endpoint module's URL and error classifier.

  These pin the contract that the retry harness depends on. The 402
  payment-required case is the headline Venice-specific behavior worth
  locking in - retrying it is wrong because the wallet balance does not
  recover until the user tops up.
  """

  use ExUnit.Case
  alias AI.Endpoint.Venice

  test "endpoint_path is the Venice chat-completions URL" do
    assert Venice.endpoint_path() == "https://api.venice.ai/api/v1/chat/completions"
  end

  describe "endpoint_error_classify/4" do
    test "402 maps to {:fail, :payment_required, _}" do
      assert {:fail, :payment_required, msg} = Venice.endpoint_error_classify(402, "{}", nil, nil)
      assert is_binary(msg)
    end

    test "401 / 403 are hard fails" do
      assert {:fail, :unauthorized, _} = Venice.endpoint_error_classify(401, "", nil, nil)
      assert {:fail, :forbidden, _} = Venice.endpoint_error_classify(403, "", nil, nil)
    end

    test "429 with no rate-limit headers retries with no caller-side wait" do
      assert {:retry, :throttled, nil} = Venice.endpoint_error_classify(429, "{}", nil, nil)
      assert {:retry, :throttled, nil} = Venice.endpoint_error_classify(429, "{}", [], nil)
    end

    test "429 picks the soonest positive reset across requests/tokens headers" do
      # tokens reset is 5s out; requests reset is 30s out -> tokens wins.
      now_ms = System.system_time(:millisecond)
      reset_unix = div(now_ms, 1000) + 30

      headers = [
        {"X-RateLimit-Reset-Requests", Integer.to_string(reset_unix)},
        {"x-ratelimit-reset-tokens", "5"}
      ]

      assert {:retry, :throttled, ms} = Venice.endpoint_error_classify(429, "{}", headers, nil)
      # Allow a small drift (header parsing reads system_time twice).
      assert ms in 4_500..5_500
    end

    test "429 ignores reset headers that have already elapsed (clamps to 0)" do
      headers = [
        # Unix timestamp 100 seconds in the past.
        {"x-ratelimit-reset-requests", Integer.to_string(div(System.system_time(:millisecond), 1000) - 100)}
      ]

      assert {:retry, :throttled, 0} = Venice.endpoint_error_classify(429, "{}", headers, nil)
    end

    test "429 with malformed reset headers falls back to nil" do
      headers = [{"x-ratelimit-reset-tokens", "not-a-number"}]
      assert {:retry, :throttled, nil} = Venice.endpoint_error_classify(429, "{}", headers, nil)
    end

    test "5xx retries as a server error" do
      assert {:retry, :server_error, nil} = Venice.endpoint_error_classify(500, "", nil, nil)
      assert {:retry, :server_error, nil} = Venice.endpoint_error_classify(503, "", nil, nil)
      assert {:retry, :server_error, nil} = Venice.endpoint_error_classify(599, "", nil, nil)
    end

    test "transport timeouts and TLS glitches retry" do
      assert {:retry, :network_glitch, nil} = Venice.endpoint_error_classify(nil, nil, nil, :timeout)
      assert {:retry, :network_glitch, nil} = Venice.endpoint_error_classify(nil, nil, nil, :closed)

      assert {:retry, :network_glitch, nil} =
               Venice.endpoint_error_classify(nil, nil, nil, {:tls_alert, :anything})

      assert {:retry, :network_glitch, nil} =
               Venice.endpoint_error_classify(nil, nil, nil, {:ssl, :wat})
    end

    test "uncovered cases return :ok (no retry, no fail)" do
      assert :ok = Venice.endpoint_error_classify(418, "", nil, nil)
    end
  end
end
