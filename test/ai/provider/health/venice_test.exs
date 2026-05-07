defmodule AI.Provider.Health.VeniceTest do
  @moduledoc """
  Mirrors the OpenAI health-check tests for Venice, plus locks in the
  402 (insufficient balance) case. 402 is unique to Venice's x402
  wallet auth and worth catching as :unauthorized so the user sees the
  payment-required signal.
  """

  use ExUnit.Case
  alias AI.Provider.Health.Venice, as: Health

  setup do
    :ok = :meck.new(Http, [:no_link, :passthrough])
    on_exit(fn -> :meck.unload(Http) end)

    System.put_env("FNORD_VENICE_API_KEY", "test-key")
    on_exit(fn -> System.delete_env("FNORD_VENICE_API_KEY") end)
    :ok
  end

  test "{:ok, body} with a data array reports model count" do
    :meck.expect(Http, :get, fn _url, _headers ->
      {:ok, ~s({"data": [{"id":"kimi-k2-6"}]})}
    end)

    assert {:ok, %{model_count: 1}} = Health.check()
  end

  test "401 reports :unauthorized" do
    :meck.expect(Http, :get, fn _url, _headers -> {:http_error, {401, "", []}} end)
    assert {:error, :unauthorized, _} = Health.check()
  end

  test "402 reports :unauthorized with insufficient-balance phrasing" do
    :meck.expect(Http, :get, fn _url, _headers -> {:http_error, {402, "", []}} end)
    assert {:error, :unauthorized, msg} = Health.check()
    assert msg =~ "insufficient balance"
  end

  test "transport error reports :unreachable" do
    :meck.expect(Http, :get, fn _url, _headers -> {:transport_error, :timeout} end)
    assert {:error, :unreachable, _} = Health.check()
  end

  test "missing API key reports :missing_api_key" do
    System.delete_env("FNORD_VENICE_API_KEY")
    System.delete_env("VENICE_API_KEY")
    assert {:error, :missing_api_key, _} = Health.check()
  end
end
