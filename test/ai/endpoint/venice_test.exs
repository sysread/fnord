defmodule AI.Endpoint.VeniceTest do
  @moduledoc """
  Tests for the Venice endpoint module's URL and error classifier.

  These pin the contract that the retry harness depends on. The 402
  payment-required case is the headline Venice-specific behavior worth
  locking in - retrying it is wrong because the wallet balance does not
  recover until the user tops up.
  """

  use Fnord.TestCase, async: false
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

    test "429 retries with no caller-side wait regardless of headers" do
      # 429 covers both rate limit and model-overload backpressure on
      # Venice; we do not use rate-limit reset headers as a retry hint
      # because they would mis-apply to overload responses.
      assert {:retry, :throttled, nil} = Venice.endpoint_error_classify(429, "{}", nil, nil)
      assert {:retry, :throttled, nil} = Venice.endpoint_error_classify(429, "{}", [], nil)

      headers = [
        {"x-ratelimit-reset-requests", "1700000000000"},
        {"x-ratelimit-reset-tokens", "5"}
      ]

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
