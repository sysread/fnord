defmodule HttpOverrideTest do
  use Fnord.TestCase, async: false

  alias HttpPool

  setup do
    HttpPool.clear()
    :meck.new(HTTPoison, [:no_link, :passthrough, :non_strict])
    on_exit(fn -> :meck.unload(HTTPoison) end)
    :ok
  end

  defp json_headers, do: [{"Content-Type", "application/json"}]

  test "post_json uses default :ai_api pool" do
    :meck.expect(HTTPoison, :post, fn _url, _body, _headers, opts ->
      assert opts[:hackney_options] == [pool: :ai_api]
      {:ok, %{status_code: 200, body: ~s({})}}
    end)

    assert {:ok, %{}} == Http.post_json("http://example", json_headers(), %{})
  end

  test "post_json uses overridden :ai_indexer pool" do
    HttpPool.set(:ai_indexer)

    :meck.expect(HTTPoison, :post, fn _url, _body, _headers, opts ->
      assert opts[:hackney_options] == [pool: :ai_indexer]
      {:ok, %{status_code: 200, body: ~s({})}}
    end)

    assert {:ok, %{}} == Http.post_json("http://example", json_headers(), %{})
    HttpPool.clear()
  end
end
