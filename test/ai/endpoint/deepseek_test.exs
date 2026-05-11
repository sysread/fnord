defmodule AI.Endpoint.DeepSeekTest do
  @moduledoc """
  Tests for the DeepSeek endpoint module's URL and error classifier.
  """

  use Fnord.TestCase, async: false
  alias AI.Endpoint.DeepSeek

  test "endpoint_path is the DeepSeek chat-completions URL" do
    assert DeepSeek.endpoint_path() == "https://api.deepseek.com/chat/completions"
  end

  describe "endpoint_error_classify/4" do
    test "401 / 403 are hard fails" do
      assert {:fail, :unauthorized, _} = DeepSeek.endpoint_error_classify(401, "", nil, nil)
      assert {:fail, :forbidden, _} = DeepSeek.endpoint_error_classify(403, "", nil, nil)
    end

    test "429 retries with no caller-side wait hint" do
      assert {:retry, :throttled, nil} = DeepSeek.endpoint_error_classify(429, "{}", nil, nil)
      assert {:retry, :throttled, nil} = DeepSeek.endpoint_error_classify(429, "{}", [], nil)
    end

    test "5xx retries as a server error" do
      assert {:retry, :server_error, nil} = DeepSeek.endpoint_error_classify(500, "", nil, nil)
      assert {:retry, :server_error, nil} = DeepSeek.endpoint_error_classify(503, "", nil, nil)
      assert {:retry, :server_error, nil} = DeepSeek.endpoint_error_classify(599, "", nil, nil)
    end

    test "transport timeouts and TLS glitches retry" do
      assert {:retry, :network_glitch, nil} =
               DeepSeek.endpoint_error_classify(nil, nil, nil, :timeout)

      assert {:retry, :network_glitch, nil} =
               DeepSeek.endpoint_error_classify(nil, nil, nil, :closed)

      assert {:retry, :network_glitch, nil} =
               DeepSeek.endpoint_error_classify(nil, nil, nil, {:tls_alert, :anything})

      assert {:retry, :network_glitch, nil} =
               DeepSeek.endpoint_error_classify(nil, nil, nil, {:ssl, :wat})
    end

    test "uncovered cases return :ok (no retry, no fail)" do
      assert :ok = DeepSeek.endpoint_error_classify(418, "", nil, nil)
    end
  end
end
