defmodule AI.Provider.ResponseParser.VeniceTest do
  @moduledoc """
  Behavioral tests for the Venice response parser.

  The headline locked-in behaviors:

  - Web-search responses get a deterministic "Sources:" section
    appended to the assistant text.
  - 402 produces a clear payment-required message instead of a raw
    inspected error map.
  """

  use Fnord.TestCase, async: false
  alias AI.Provider.ResponseParser.Venice, as: Parser

  describe "parse_success/1" do
    test "extracts assistant text and total_tokens usage" do
      body = %{
        "choices" => [%{"message" => %{"content" => "hello"}}],
        "usage" => %{"total_tokens" => 7}
      }

      assert {:ok, :msg, "hello", 7} = Parser.parse_success(body)
    end

    test "extracts tool_calls in OpenAI-compatible shape" do
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
        "usage" => %{"total_tokens" => 0}
      }

      assert {:ok, :tool, [%{id: "id1", function: %{name: "f", arguments: "{}"}}]} =
               Parser.parse_success(body)
    end

    test "appends a numbered Sources section when web_search_citations is present" do
      body = %{
        "choices" => [%{"message" => %{"content" => "Per the sources^1^^2^, X."}}],
        "usage" => %{"total_tokens" => 1},
        "venice_parameters" => %{
          "web_search_citations" => [
            %{"title" => "First", "url" => "https://a.example"},
            %{"title" => "Second", "url" => "https://b.example"}
          ]
        }
      }

      assert {:ok, :msg, text, 1} = Parser.parse_success(body)
      assert text =~ "Per the sources"
      assert text =~ "Sources:"
      assert text =~ "1. First - https://a.example"
      assert text =~ "2. Second - https://b.example"
    end

    test "no Sources section when citations are absent or empty" do
      body_no_vp = %{
        "choices" => [%{"message" => %{"content" => "x"}}],
        "usage" => %{"total_tokens" => 0}
      }

      body_empty = %{
        "choices" => [%{"message" => %{"content" => "x"}}],
        "usage" => %{"total_tokens" => 0},
        "venice_parameters" => %{"web_search_citations" => []}
      }

      assert {:ok, :msg, "x", 0} = Parser.parse_success(body_no_vp)
      assert {:ok, :msg, "x", 0} = Parser.parse_success(body_empty)
    end

    test "citation lines fall back to URL or title when one is missing" do
      body = %{
        "choices" => [%{"message" => %{"content" => "see refs"}}],
        "usage" => %{"total_tokens" => 0},
        "venice_parameters" => %{
          "web_search_citations" => [
            %{"url" => "https://only-url.example"},
            %{"title" => "Only title"}
          ]
        }
      }

      assert {:ok, :msg, text, 0} = Parser.parse_success(body)
      assert text =~ "1. https://only-url.example"
      assert text =~ "2. Only title"
    end

    test "unrecognized shape becomes a structured 500" do
      assert {:error, %{http_status: 500, error: msg}} = Parser.parse_success(%{"weird" => 1})
      assert is_binary(msg)
    end
  end

  describe "parse_error/2" do
    test "402 surfaces a clear payment-required message" do
      assert {:error, %{http_status: 402, code: "payment_required", message: msg}} =
               Parser.parse_error(402, "anything")

      assert msg =~ "insufficient balance"
    end

    test "502/503/504 surface as :api_unavailable" do
      assert {:error, :api_unavailable, "down"} = Parser.parse_error(502, "down")
      assert {:error, :api_unavailable, "down"} = Parser.parse_error(503, "down")
      assert {:error, :api_unavailable, "down"} = Parser.parse_error(504, "down")
    end

    test "structured error maps come through with code and message" do
      body = ~s({"error":{"code":"invalid_request","message":"Bad model"}})

      assert {:error,
              %{
                http_status: 400,
                code: "invalid_request",
                message: "Bad model"
              }} = Parser.parse_error(400, body)
    end

    test "non-JSON body surfaces verbatim under :error" do
      body = "Plain text from an intermediary"
      assert {:error, %{http_status: 400, error: ^body}} = Parser.parse_error(400, body)
    end
  end
end
