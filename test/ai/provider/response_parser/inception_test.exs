defmodule AI.Provider.ResponseParser.InceptionTest do
  @moduledoc """
  Behavioral tests for the Inception Labs response-parser. Inception is
  OpenAI-API-compatible at the response shape, so the success-path
  parsing mirrors OpenAI's. The error path has typed `:throttled` and
  `:api_unavailable` mappings.
  """

  use Fnord.TestCase, async: false
  alias AI.Provider.ResponseParser.Inception, as: Parser

  describe "parse_success/1" do
    test "extracts text content and total_tokens from choices/usage" do
      body = %{
        "choices" => [
          %{"message" => %{"content" => "hello", "usage" => %{}}}
        ],
        "usage" => %{"total_tokens" => 42}
      }

      assert {:ok, :msg, "hello", 42} = Parser.parse_success(body)
    end

    test "extracts tool_calls when message has them" do
      body = %{
        "choices" => [
          %{
            "message" => %{
              "tool_calls" => [
                %{"id" => "call_1", "function" => %{"name" => "f", "arguments" => "{}"}}
              ]
            }
          }
        ],
        "usage" => %{"total_tokens" => 10}
      }

      assert {:ok, :tool, [%{id: "call_1", function: %{name: "f", arguments: "{}"}}]} =
               Parser.parse_success(body)
    end

    test "unexpected response shape becomes a structured error" do
      assert {:error, %{http_status: 500, error: _}} =
               Parser.parse_success(%{"unexpected" => true})
    end
  end

  describe "parse_error/2" do
    test "502/503/504 are :api_unavailable" do
      assert {:error, :api_unavailable, _} = Parser.parse_error(502, "down")
      assert {:error, :api_unavailable, _} = Parser.parse_error(503, "down")
      assert {:error, :api_unavailable, _} = Parser.parse_error(504, "down")
    end

    test "429 surfaces as typed :throttled with the message extracted" do
      body = ~s({"error":{"code":"rate_limit_exceeded","message":"slow down"}})
      assert {:error, :throttled, "slow down"} = Parser.parse_error(429, body)
    end

    test "429 with non-JSON body surfaces the raw body as the reason" do
      body = "rate limit exceeded - try again"
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

    test "plaintext body surfaces verbatim under :error" do
      body = "Something went wrong"
      assert {:error, %{http_status: 400, error: ^body}} = Parser.parse_error(400, body)
    end

    test "non-binary body falls through the defensive catch-all" do
      assert {:error, %{http_status: 500, error: _}} = Parser.parse_error(500, %{not: :binary})
    end
  end
end
