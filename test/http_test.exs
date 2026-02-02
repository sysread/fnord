defmodule HttpTest do
  use Fnord.TestCase, async: false

  setup do
    :meck.new(HTTPoison, [:no_link, :passthrough, :non_strict])
    on_exit(fn -> :meck.unload(HTTPoison) end)
    :ok
  end

  defp json_headers, do: [{"Content-Type", "application/json"}]

  test "immediate success returns decoded JSON without retries" do
    :meck.expect(HTTPoison, :post, fn _url, _body, _headers, _opts ->
      {:ok, %HTTPoison.Response{status_code: 200, headers: [], body: ~s({"ok":true})}}
    end)

    assert {:ok, %{body: %{"ok" => true}, status: 200, headers: _}} =
             Http.post_json("http://example", json_headers(), %{a: 1})
  end

  test "retries once on 500 then succeeds" do
    call_count_ref = make_ref()
    Process.put(call_count_ref, 0)

    :meck.expect(HTTPoison, :post, fn _url, _body, _headers, _opts ->
      n = (Process.get(call_count_ref) || 0) + 1
      Process.put(call_count_ref, n)

      case n do
        1 -> {:ok, %HTTPoison.Response{status_code: 500, headers: [], body: "err"}}
        _ -> {:ok, %HTTPoison.Response{status_code: 200, headers: [], body: ~s({"ok":true})}}
      end
    end)

    assert {:ok, %{body: %{"ok" => true}, status: 200, headers: _}} =
             Http.post_json("http://example", json_headers(), %{a: 1})

    assert (Process.get(call_count_ref) || 0) == 2
  end

  test "does not retry on 429 and returns http_error" do
    :meck.expect(HTTPoison, :post, fn _url, _body, _headers, _opts ->
      {:ok, %HTTPoison.Response{status_code: 429, headers: [], body: "rate limit"}}
    end)

    assert {:http_error, {429, "rate limit"}} =
             Http.post_json("http://example", json_headers(), %{})
  end

  test "retries transport :timeout then succeeds" do
    call_count_ref = make_ref()
    Process.put(call_count_ref, 0)

    :meck.expect(HTTPoison, :post, fn _url, _body, _headers, _opts ->
      n = (Process.get(call_count_ref) || 0) + 1
      Process.put(call_count_ref, n)

      case n do
        1 -> {:error, %HTTPoison.Error{reason: :timeout}}
        _ -> {:ok, %HTTPoison.Response{status_code: 200, headers: [], body: ~s({"ok":true})}}
      end
    end)

    assert {:ok, %{body: %{"ok" => true}, status: 200, headers: _}} =
             Http.post_json("http://example", json_headers(), %{a: 1})

    assert (Process.get(call_count_ref) || 0) == 2
  end

  test "json encode error does not retry and returns invalid_json_response" do
    # Payload with a PID cannot be encoded by Jason
    bad_payload = %{pid: self()}

    assert {:transport_error, :invalid_json_response} =
             Http.post_json("http://example", json_headers(), bad_payload)
  end

  test "logs response body with UI debug message before returning invalid_json_response" do
    :meck.expect(HTTPoison, :post, fn _url, _body, _headers, _opts ->
      {:ok, %HTTPoison.Response{status_code: 200, headers: [], body: "not json"}}
    end)

    expect(UI.Output.Mock, :log, fn level, msg ->
      assert level == :debug
      msg = IO.iodata_to_binary(msg)
      assert msg =~ "[http] invalid JSON response"
      assert msg =~ "not json"
      :ok
    end)

    assert {:transport_error, :invalid_json_response} =
             Http.post_json("http://example", json_headers(), %{a: 1})
  end

  test "fails after 10 attempts of 5xx" do
    call_count_ref = make_ref()
    Process.put(call_count_ref, 0)

    :meck.expect(HTTPoison, :post, fn _url, _body, _headers, _opts ->
      n = (Process.get(call_count_ref) || 0) + 1
      Process.put(call_count_ref, n)
      {:ok, %HTTPoison.Response{status_code: 500, headers: [], body: "err"}}
    end)

    assert {:http_error, {500, "err"}} = Http.post_json("http://example", json_headers(), %{a: 1})
    assert (Process.get(call_count_ref) || 0) == 10
  end
end
