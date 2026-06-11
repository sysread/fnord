defmodule HttpOverrideTest do
  use Fnord.TestCase, async: true

  alias HttpPool

  # HttpPool overrides live in the process dictionary, so each async test
  # process gets its own; clear defensively in case a helper set one.
  setup do
    HttpPool.clear()
    :ok
  end

  defp json_headers, do: [{"Content-Type", "application/json"}]

  test "post_json uses default :ai_api pool" do
    stub(Http.Client.Mock, :post, fn _url, _body, _headers, opts ->
      assert opts[:hackney_options] == [pool: :ai_api]
      {:ok, %HTTPoison.Response{status_code: 200, headers: [], body: ~s({})}}
    end)

    assert {:ok, %{body: %{}, status: 200, headers: _}} =
             Http.post_json("http://example", json_headers(), %{})
  end

  test "post_json uses overridden :ai_indexer pool" do
    HttpPool.set(:ai_indexer)

    stub(Http.Client.Mock, :post, fn _url, _body, _headers, opts ->
      assert opts[:hackney_options] == [pool: :ai_indexer]
      {:ok, %HTTPoison.Response{status_code: 200, headers: [], body: ~s({})}}
    end)

    assert {:ok, %{body: %{}, status: 200, headers: _}} =
             Http.post_json("http://example", json_headers(), %{})

    HttpPool.clear()
  end
end
