defmodule AI.Endpoint.InceptionTest do
  @moduledoc """
  Tests for the Inception Labs endpoint module's URL and error classifier.

  Mirrors the Venice and OpenAI endpoint test shape - pins the contract
  that the retry harness depends on.
  """

  use Fnord.TestCase, async: false
  alias AI.Endpoint.Inception

  test "endpoint_path is the Inception chat-completions URL" do
    assert Inception.endpoint_path() == "https://api.inceptionlabs.ai/v1/chat/completions"
  end

  describe "endpoint_error_classify/4" do
    test "401 / 403 are hard fails" do
      assert {:fail, :unauthorized, _} = Inception.endpoint_error_classify(401, "", nil, nil)
      assert {:fail, :forbidden, _} = Inception.endpoint_error_classify(403, "", nil, nil)
    end

    test "429 retries with no caller-side wait hint" do
      assert {:retry, :throttled, nil} = Inception.endpoint_error_classify(429, "{}", nil, nil)
      assert {:retry, :throttled, nil} = Inception.endpoint_error_classify(429, "{}", [], nil)
    end

    test "5xx retries as a server error" do
      assert {:retry, :server_error, nil} = Inception.endpoint_error_classify(500, "", nil, nil)
      assert {:retry, :server_error, nil} = Inception.endpoint_error_classify(503, "", nil, nil)
      assert {:retry, :server_error, nil} = Inception.endpoint_error_classify(599, "", nil, nil)
    end

    test "transport timeouts and TLS glitches retry" do
      assert {:retry, :network_glitch, nil} =
               Inception.endpoint_error_classify(nil, nil, nil, :timeout)

      assert {:retry, :network_glitch, nil} =
               Inception.endpoint_error_classify(nil, nil, nil, :closed)

      assert {:retry, :network_glitch, nil} =
               Inception.endpoint_error_classify(nil, nil, nil, {:tls_alert, :anything})

      assert {:retry, :network_glitch, nil} =
               Inception.endpoint_error_classify(nil, nil, nil, {:ssl, :wat})
    end

    test "uncovered cases return :ok (no retry, no fail)" do
      assert :ok = Inception.endpoint_error_classify(418, "", nil, nil)
    end
  end
end
