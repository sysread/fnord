defmodule AI.Provider.ResponseParser.OpenAITest do
  @moduledoc """
  Behavioral tests for the OpenAI response parser.

  Pinning these at the per-provider level means future changes to the
  orchestration layer cannot accidentally drop a special-case (the
  `:context_length_exceeded` path is the most important one - it
  triggers compaction in `AI.Completion`).
  """

  use Fnord.TestCase, async: false
  alias AI.Provider.ResponseParser.OpenAI, as: Parser

  describe "parse_success/1" do
    test "extracts assistant text and total_tokens usage" do
      body = %{
        "choices" => [
          %{"message" => %{"content" => "hello"}}
        ],
        "usage" => %{"total_tokens" => 42}
      }

      assert {:ok, :msg, "hello", 42} = Parser.parse_success(body)
    end

    test "extracts tool_calls" do
      body = %{
        "choices" => [
          %{
            "message" => %{
              "tool_calls" => [
                %{"id" => "id1", "function" => %{"name" => "f", "arguments" => "{}"}}
              ]
            }
          }
        ],
        "usage" => %{"total_tokens" => 1}
      }

      assert {:ok, :tool, [%{id: "id1", function: %{name: "f", arguments: "{}"}}]} =
               Parser.parse_success(body)
    end

    test "unrecognized shape becomes a structured 500" do
      assert {:error, %{http_status: 500, error: msg}} = Parser.parse_success(%{"weird" => 1})
      assert is_binary(msg)
    end
  end

  describe "parse_error/2" do
    test "502/503/504 surface as :api_unavailable" do
      assert {:error, :api_unavailable, "down"} = Parser.parse_error(502, "down")
      assert {:error, :api_unavailable, "down"} = Parser.parse_error(503, "down")
      assert {:error, :api_unavailable, "down"} = Parser.parse_error(504, "down")
    end

    test "context_length_exceeded extracts used token count" do
      body =
        ~s({"error":{"message":"Your messages resulted in 12345 tokens","code":"context_length_exceeded"}})

      assert {:error, :context_length_exceeded, 12345} = Parser.parse_error(400, body)
    end

    test "context_length_exceeded without token count gives -1 sentinel" do
      body = ~s({"error":{"message":"Too long","code":"context_length_exceeded"}})
      assert {:error, :context_length_exceeded, -1} = Parser.parse_error(400, body)
    end

    test "429 surfaces as typed :throttled with the message extracted" do
      # 429 reaches the parser only after AI.Endpoint exhausts retries.
      # Surfacing as a typed atom lets callers (e.g. memory_indexer
      # dedup) recognize the transient nature and decide whether to
      # surface, retry-later, or downgrade.
      body = ~s({"error":{"code":"rate_limit_exceeded","message":"slow down"}})
      assert {:error, :throttled, "slow down"} = Parser.parse_error(429, body)
    end

    test "429 with non-JSON body surfaces the raw body as the reason" do
      body = "rate limit exceeded - try again later"
      assert {:error, :throttled, ^body} = Parser.parse_error(429, body)
    end

    test "other structured errors come through as a map" do
      body = ~s({"error":{"code":"invalid_request","message":"missing field"}})

      assert {:error,
              %{
                http_status: 400,
                code: "invalid_request",
                message: "missing field"
              }} = Parser.parse_error(400, body)
    end

    test "non-JSON body surfaces verbatim under :error" do
      # Use a 4xx so we hit the JSON-decode path (not the dedicated 502/3/4
      # api_unavailable shortcut) and exercise the plaintext-body fallback.
      body = "Cloudflare did a thing"
      assert {:error, %{http_status: 400, error: ^body}} = Parser.parse_error(400, body)
    end
  end
end
