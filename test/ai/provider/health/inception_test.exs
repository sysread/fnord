defmodule AI.Provider.Health.InceptionTest do
  @moduledoc """
  Health-check tests for the Inception Labs provider. Mirrors the
  OpenAI/Venice shape; Inception is OpenAI-API-compatible at the
  /v1/models endpoint.
  """

  use Fnord.TestCase, async: false
  alias AI.Provider.Health.Inception, as: Health

  setup do
    :ok = :meck.new(Http, [:no_link, :passthrough])
    on_exit(fn -> :meck.unload(Http) end)

    System.put_env("FNORD_INCEPTION_API_KEY", "test-key")
    on_exit(fn -> System.delete_env("FNORD_INCEPTION_API_KEY") end)
    :ok
  end

  test "{:ok, body} with a data array reports model count" do
    :meck.expect(Http, :get, fn _url, _headers ->
      {:ok, ~s({"data": [{"id":"mercury-2"}]})}
    end)

    assert {:ok, %{model_count: 1}} = Health.check()
  end

  test "401 reports :unauthorized" do
    :meck.expect(Http, :get, fn _url, _headers -> {:http_error, {401, ""}} end)
    assert {:error, :unauthorized, _} = Health.check()
  end

  test "5xx reports :other" do
    :meck.expect(Http, :get, fn _url, _headers -> {:http_error, {503, "Down"}} end)
    assert {:error, :other, _} = Health.check()
  end

  test "{:ok, body} with an unexpected shape becomes :other" do
    :meck.expect(Http, :get, fn _url, _headers -> {:ok, ~s({"surprise": true})} end)
    assert {:error, :other, _} = Health.check()
  end

  test "transport error reports :unreachable" do
    :meck.expect(Http, :get, fn _url, _headers -> {:transport_error, :timeout} end)
    assert {:error, :unreachable, _} = Health.check()
  end

  test "missing API key reports :missing_api_key" do
    System.delete_env("FNORD_INCEPTION_API_KEY")
    System.delete_env("INCEPTION_API_KEY")
    assert {:error, :missing_api_key, _} = Health.check()
  end
end
