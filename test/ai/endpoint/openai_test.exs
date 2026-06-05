defmodule AI.Endpoint.OpenAITest do
  use ExUnit.Case, async: true

  alias AI.Endpoint.OpenAI

  describe "endpoint_error_classify/4 — rate-limit retry hint parsing" do
    # OpenAI surfaces two hint formats in the 429 body depending on wait length.
    # The retry layer trusts whatever wait_ms comes back; getting this wrong
    # means we backoff for less time than OpenAI told us to and re-hit the cap.

    test "honors integer-ms hint" do
      body =
        Jason.encode!(%{
          "error" => %{
            "code" => "rate_limit_exceeded",
            "message" => "Rate limit reached. Please try again in 250ms."
          }
        })

      assert {:retry, :throttled, 250} = OpenAI.endpoint_error_classify(429, body, nil, nil)
    end

    test "honors fractional-second hint (1.566s -> 1566ms)" do
      body =
        Jason.encode!(%{
          "error" => %{
            "code" => "rate_limit_exceeded",
            "message" =>
              "Rate limit reached for gpt-4.1. Limit 30000. Please try again in 1.566s."
          }
        })

      assert {:retry, :throttled, 1566} = OpenAI.endpoint_error_classify(429, body, nil, nil)
    end

    test "honors integer-second hint (2s -> 2000ms)" do
      body =
        Jason.encode!(%{
          "error" => %{
            "code" => "rate_limit_exceeded",
            "message" => "Please try again in 2s."
          }
        })

      assert {:retry, :throttled, 2000} = OpenAI.endpoint_error_classify(429, body, nil, nil)
    end

    test "honors fractional-ms hint (1500.5ms -> 1501)" do
      body =
        Jason.encode!(%{
          "error" => %{
            "code" => "rate_limit_exceeded",
            "message" => "Please try again in 1500.5ms."
          }
        })

      assert {:retry, :throttled, 1501} = OpenAI.endpoint_error_classify(429, body, nil, nil)
    end

    test "retries with no hint when body lacks a try-again clause" do
      body =
        Jason.encode!(%{
          "error" => %{"code" => "rate_limit_exceeded", "message" => "Too many requests"}
        })

      assert {:retry, :throttled, nil} = OpenAI.endpoint_error_classify(429, body, nil, nil)
    end
  end
end
