defmodule AI.Provider.ResponseParser.DeepSeekTest do
  @moduledoc """
  Behavioral tests for the DeepSeek response-parser. DeepSeek is
  OpenAI-API-compatible at the response shape.
  """

  use Fnord.TestCase, async: false
  alias AI.Provider.ResponseParser.DeepSeek, as: Parser

  describe "parse_success/1" do
    test "extracts text content and total_tokens from choices/usage" do
      body = %{
        "choices" => [%{"message" => %{"content" => "hello", "usage" => %{}}}],
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

    test "reasoning_content surfaces as a 5-tuple for round-tripping" do
      # DeepSeek's thinking-mode models include reasoning_content
      # alongside content. The parser must surface it so the
      # orchestration layer can attach it to the assistant message;
      # subsequent turns require it round-tripped or DeepSeek rejects.
      body = %{
        "choices" => [
          %{
            "message" => %{
              "content" => "final answer",
              "reasoning_content" => "let me think...",
              "usage" => %{}
            }
          }
        ],
        "usage" => %{"total_tokens" => 100}
      }

      assert {:ok, :msg, "final answer", 100, "let me think..."} = Parser.parse_success(body)
    end

    test "empty/nil reasoning_content falls through to 4-tuple shape" do
      # The reasoning_content field is only meaningful when populated.
      # Empty string or missing field -> use the legacy 4-tuple so
      # the orchestration layer doesn't attach a useless field.
      body_empty = %{
        "choices" => [
          %{
            "message" => %{
              "content" => "answer",
              "reasoning_content" => "",
              "usage" => %{}
            }
          }
        ],
        "usage" => %{"total_tokens" => 10}
      }

      assert {:ok, :msg, "answer", 10} = Parser.parse_success(body_empty)
    end

    test "null tool_calls are not treated as present" do
      body = %{
        "choices" => [%{"message" => %{"content" => "hi", "tool_calls" => nil, "usage" => %{}}}],
        "usage" => %{"total_tokens" => 5}
      }

      assert {:ok, :msg, "hi", 5} = Parser.parse_success(body)
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
