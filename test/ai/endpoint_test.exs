defmodule AI.EndpointTest do
  use Fnord.TestCase, async: false

  setup do
    :meck.new(HTTPoison, [:no_link, :passthrough, :non_strict])
    on_exit(fn -> :meck.unload(HTTPoison) end)
    :ok
  end

  defmodule DummyEndpoint do
    @behaviour AI.Endpoint

    @impl AI.Endpoint
    def endpoint_path, do: "http://example"
  end

  defp json_headers, do: [{"Content-Type", "application/json"}]

  test "retries on 429 when throttling error code is rate_limit_exceeded" do
    call_count_ref = make_ref()
    Process.put(call_count_ref, 0)

    throttled_body =
      Jason.encode!(%{
        "error" => %{
          "code" => "rate_limit_exceeded",
          "message" => "Rate limit reached. Please try again in 1ms."
        }
      })

    :meck.expect(HTTPoison, :post, fn _url, _body, _headers, _opts ->
      n = (Process.get(call_count_ref) || 0) + 1
      Process.put(call_count_ref, n)

      case n do
        1 -> {:ok, %{status_code: 429, body: throttled_body}}
        _ -> {:ok, %{status_code: 200, body: ~s({"ok":true})}}
      end
    end)

    assert {:ok, %{"ok" => true}} == AI.Endpoint.post_json(DummyEndpoint, json_headers(), %{a: 1})
    assert (Process.get(call_count_ref) || 0) == 2
  end

  test "consults Store.APIUsage when deciding to retry based on API usage" do
    call_count_ref = make_ref()
    Process.put(call_count_ref, 0)

    # Write API usage file in the same format Store.APIUsage persists:
    # a map keyed by model name with integer timestamps (ms).
    now = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

    File.write!(
      Store.APIUsage.store_path(),
      Jason.encode!(%{
        "gpt-4o-mini" => %{
          "updated_at" => now,
          "requests_max" => 100,
          "requests_left" => 0,
          "requests_reset" => 10_000,
          "tokens_max" => 1000,
          "tokens_left" => 0,
          "tokens_reset" => 10_000
        }
      })
    )

    throttled_body =
      Jason.encode!(%{
        "error" => %{
          "code" => "rate_limit_exceeded",
          "message" => "Rate limit reached."
        }
      })

    :meck.expect(HTTPoison, :post, fn _url, _body, _headers, _opts ->
      n = (Process.get(call_count_ref) || 0) + 1
      Process.put(call_count_ref, n)

      case n do
        1 ->
          {:ok, %{status_code: 429, body: throttled_body}}

        _ ->
          {:ok, %{status_code: 200, body: ~s({"ok":true})}}
      end
    end)

    assert {:ok, %{"ok" => true}} ==
             AI.Endpoint.post_json(DummyEndpoint, json_headers(), %{a: 1, model: "gpt-4o-mini"})

    assert (Process.get(call_count_ref) || 0) == 2
  end

  test "does not retry on 429 when throttling error code is not recognized" do
    call_count_ref = make_ref()
    Process.put(call_count_ref, 0)

    body =
      Jason.encode!(%{
        "error" => %{
          "code" => "insufficient_quota",
          "message" => "No soup for you"
        }
      })

    :meck.expect(HTTPoison, :post, fn _url, _body, _headers, _opts ->
      n = (Process.get(call_count_ref) || 0) + 1
      Process.put(call_count_ref, n)
      {:ok, %{status_code: 429, body: body}}
    end)

    assert {:http_error, {429, ^body}} =
             AI.Endpoint.post_json(DummyEndpoint, json_headers(), %{a: 1})

    assert (Process.get(call_count_ref) || 0) == 1
  end

  test "pauses background indexing after consecutive throttling reaches threshold for a model" do
    Services.Globals.put_env(:fnord, :http_retry_skip_sleep, true)
    Services.BgIndexingControl.set_threshold(3)
    call_count_ref = make_ref()
    Process.put(call_count_ref, 0)

    throttled_body =
      Jason.encode!(%{
        "error" => %{
          "code" => "rate_limit_exceeded",
          "message" => "Too many requests"
        }
      })

    :meck.expect(HTTPoison, :post, fn _url, _body, _headers, _opts ->
      n = (Process.get(call_count_ref) || 0) + 1
      Process.put(call_count_ref, n)
      {:ok, %{status_code: 429, body: throttled_body}}
    end)

    on_exit(fn ->
      Services.BgIndexingControl.clear_pause(AI.Model.fast().model)
    end)

    Enum.each(1..3, fn _ ->
      AI.Endpoint.post_json(DummyEndpoint, json_headers(), %{a: 1, model: AI.Model.fast().model})
    end)

    assert Services.BgIndexingControl.paused?(AI.Model.fast().model)
  end
end
