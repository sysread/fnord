defmodule MCP.OAuth2.RegistrationTest do
  use Fnord.TestCase, async: false

  setup do
    :meck.new(HTTPoison, [:passthrough])

    on_exit(fn ->
      try do
        :meck.unload(HTTPoison)
      catch
        _, _ -> :ok
      end
    end)

    :ok
  end

  describe "register/2" do
    test "registers client with default configuration" do
      registration_response = %{
        "client_id" => "dynamic-client-123",
        "client_id_issued_at" => System.os_time(:second)
      }

      :meck.expect(HTTPoison, :post, fn url, body, headers, _opts ->
        assert url == "https://example.com/register"
        assert {"Content-Type", "application/json"} in headers

        request = Jason.decode!(body)
        assert request["client_name"] == "fnord"
        assert request["redirect_uris"] == ["http://localhost:8080/callback"]
        assert request["grant_types"] == ["authorization_code", "refresh_token"]
        assert request["response_types"] == ["code"]
        assert request["token_endpoint_auth_method"] == "none"
        assert request["application_type"] == "native"

        {:ok, %{status_code: 201, body: Jason.encode!(registration_response)}}
      end)

      assert {:ok, result} = MCP.OAuth2.Registration.register("https://example.com/register")
      assert result.client_id == "dynamic-client-123"
      assert result.client_secret == nil
    end

    test "registers client with custom redirect URIs" do
      registration_response = %{
        "client_id" => "custom-client",
        "client_secret" => "secret-123"
      }

      :meck.expect(HTTPoison, :post, fn _url, body, _headers, _opts ->
        request = Jason.decode!(body)
        assert request["redirect_uris"] == ["http://localhost:9090/callback"]

        {:ok, %{status_code: 201, body: Jason.encode!(registration_response)}}
      end)

      assert {:ok, result} =
               MCP.OAuth2.Registration.register("https://example.com/register",
                 redirect_uris: ["http://localhost:9090/callback"]
               )

      assert result.client_id == "custom-client"
      assert result.client_secret == "secret-123"
    end

    test "registers client with custom client name" do
      registration_response = %{
        "client_id" => "named-client"
      }

      :meck.expect(HTTPoison, :post, fn _url, body, _headers, _opts ->
        request = Jason.decode!(body)
        assert request["client_name"] == "MyApp"

        {:ok, %{status_code: 201, body: Jason.encode!(registration_response)}}
      end)

      assert {:ok, result} =
               MCP.OAuth2.Registration.register("https://example.com/register",
                 client_name: "MyApp"
               )

      assert result.client_id == "named-client"
    end

    test "accepts 200 status code for registration" do
      registration_response = %{
        "client_id" => "client-200"
      }

      :meck.expect(HTTPoison, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status_code: 200, body: Jason.encode!(registration_response)}}
      end)

      assert {:ok, result} = MCP.OAuth2.Registration.register("https://example.com/register")
      assert result.client_id == "client-200"
    end

    test "returns error when registration fails with HTTP error" do
      :meck.expect(HTTPoison, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status_code: 400, body: "Invalid request"}}
      end)

      assert {:error, {:registration_failed, 400}} =
               MCP.OAuth2.Registration.register("https://example.com/register")
    end

    test "returns error when network request fails" do
      :meck.expect(HTTPoison, :post, fn _url, _body, _headers, _opts ->
        raise HTTPoison.Error, reason: :timeout
      end)

      assert {:error, {:network_error, :timeout}} =
               MCP.OAuth2.Registration.register("https://example.com/register")
    end

    test "returns error when response is missing client_id" do
      :meck.expect(HTTPoison, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status_code: 201, body: Jason.encode!(%{"foo" => "bar"})}}
      end)

      assert {:error, :missing_client_id} =
               MCP.OAuth2.Registration.register("https://example.com/register")
    end

    test "returns error when response JSON is invalid" do
      :meck.expect(HTTPoison, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status_code: 201, body: "not json"}}
      end)

      assert {:error, {:invalid_json, _}} =
               MCP.OAuth2.Registration.register("https://example.com/register")
    end
  end
end
