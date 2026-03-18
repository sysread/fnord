defmodule AI.EmbeddingsTest do
  use Fnord.TestCase, async: false

  setup do
    :meck.new(HTTPoison, [:no_link, :passthrough, :non_strict])
    on_exit(fn -> :meck.unload(HTTPoison) end)

    Util.Env.put_env("OPENAI_API_KEY", "test-openai-key")
    :ok
  end

  describe "get/1" do
    test "retries oversized inputs when OpenAI reports maximum input length" do
      call_count_ref = make_ref()
      Process.put(call_count_ref, 0)

      oversized_body =
        SafeJson.encode!(%{
          "error" => %{
            "message" => "Invalid 'input[0]': maximum input length is 8192 tokens.",
            "code" => "context_length_exceeded"
          }
        })

      input = String.duplicate("a", 30_000)

      first_request_sizes_ref = make_ref()
      Process.put(first_request_sizes_ref, nil)

      :meck.expect(HTTPoison, :post, fn _url, body, _headers, _opts ->
        n = (Process.get(call_count_ref) || 0) + 1
        Process.put(call_count_ref, n)

        payload = SafeJson.decode!(body)
        [first_input | _rest] = payload["input"]

        case n do
          1 ->
            Process.put(first_request_sizes_ref, Enum.map(payload["input"], &String.length/1))
            {:ok, %HTTPoison.Response{status_code: 400, headers: [], body: oversized_body}}

          _ ->
            original_sizes = Process.get(first_request_sizes_ref) || []
            assert Enum.any?(original_sizes, &(&1 > String.length(first_input)))

            response_body =
              payload["input"]
              |> Enum.with_index()
              |> Enum.map(fn {_chunk, idx} ->
                %{"embedding" => [idx * 1.0 + 1.0, idx * 1.0 + 2.0]}
              end)
              |> then(&%{"data" => &1})
              |> SafeJson.encode!()

            {:ok, %HTTPoison.Response{status_code: 200, headers: [], body: response_body}}
        end
      end)

      assert {:ok, [1.0, 2.0]} = AI.Embeddings.get(input)
      assert (Process.get(call_count_ref) || 0) >= 2
    end

    test "returns max attempts reached when a batch cannot be reduced further" do
      oversized_body =
        SafeJson.encode!(%{
          "error" => %{
            "message" => "Invalid 'input[0]': maximum input length is 8192 tokens.",
            "code" => "context_length_exceeded"
          }
        })

      :meck.expect(HTTPoison, :post, fn _url, _body, _headers, _opts ->
        {:ok, %HTTPoison.Response{status_code: 400, headers: [], body: oversized_body}}
      end)

      assert {:error, :max_attempts_reached} = AI.Embeddings.get("tiny")
    end

    test "returns http_error for non-token-limit failures" do
      :meck.expect(HTTPoison, :post, fn _url, _body, _headers, _opts ->
        {:ok, %HTTPoison.Response{status_code: 500, headers: [], body: "boom"}}
      end)

      assert {:error, :http_error} = AI.Embeddings.get("tiny")
    end
  end
end
