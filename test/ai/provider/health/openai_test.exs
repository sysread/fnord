defmodule AI.Provider.Health.OpenAITest do
  @moduledoc """
  Verifies the OpenAI health-check classifies common HTTP outcomes
  correctly. The actual HTTP layer is mocked via :meck so we can
  exercise every branch without making a real call.
  """

  use Fnord.TestCase, async: false
  alias AI.Provider.Health.OpenAI, as: Health

  setup do
    :ok = :meck.new(Http, [:no_link, :passthrough])
    on_exit(fn -> :meck.unload(Http) end)

    # The check needs an API key; treat it as set for these tests.
    System.put_env("FNORD_OPENAI_API_KEY", "test-key")
    on_exit(fn -> System.delete_env("FNORD_OPENAI_API_KEY") end)
    :ok
  end

  test "{:ok, body} with a data array reports model count" do
    :meck.expect(Http, :get, fn _url, _headers ->
      {:ok, ~s({"data": [{"id":"gpt-5"},{"id":"gpt-5-mini"}]})}
    end)

    assert {:ok, %{model_count: 2}} = Health.check()
  end

  test "{:ok, body} with an unexpected shape becomes :other" do
    :meck.expect(Http, :get, fn _url, _headers -> {:ok, ~s({"surprise": true})} end)
    assert {:error, :other, _} = Health.check()
  end

  test "401 reports :unauthorized" do
    :meck.expect(Http, :get, fn _url, _headers -> {:http_error, {401, "Bad key"}} end)
    assert {:error, :unauthorized, _} = Health.check()
  end

  test "5xx reports :other" do
    :meck.expect(Http, :get, fn _url, _headers -> {:http_error, {503, "Down"}} end)
    assert {:error, :other, _} = Health.check()
  end

  test "transport error reports :unreachable" do
    :meck.expect(Http, :get, fn _url, _headers -> {:transport_error, :timeout} end)
    assert {:error, :unreachable, _} = Health.check()
  end

  test "missing API key reports :missing_api_key" do
    System.delete_env("FNORD_OPENAI_API_KEY")
    System.delete_env("OPENAI_API_KEY")
    assert {:error, :missing_api_key, _} = Health.check()
  end
end
