defmodule MCP.OAuth2.LoopbackTest do
  use Fnord.TestCase

  describe "loopback server" do
    test "can start and build router without compilation errors" do
      # This test ensures the dynamically generated Plug router compiles
      cfg = %{
        discovery_url: "https://example.com/.well-known/oauth-authorization-server",
        client_id: "test-client-id",
        scopes: ["mcp:access"],
        redirect_uri: "http://localhost:8080/callback"
      }

      server_key = "test-server"
      expected_state = "test-state"
      code_verifier = "test-verifier"

      # Start the loopback server - this will test router compilation
      {:ok, pid} =
        MCP.OAuth2.Loopback.start_link(
          cfg: cfg,
          base_url: "https://example.com",
          server_key: server_key,
          state: expected_state,
          code_verifier: code_verifier,
          port: 0
        )

      # Get the actual port it bound to
      {:ok, port} = GenServer.call(pid, :get_port)
      assert is_integer(port)
      assert port > 0

      # Clean up
      GenServer.stop(pid)
    end

    test "router module compiles with valid Plug syntax" do
      # Minimal test to ensure the Module.create in build_router works
      cfg = %{
        discovery_url: "https://example.com/.well-known/oauth-authorization-server",
        client_id: "test-client",
        scopes: ["test"],
        redirect_uri: "http://localhost:3000/callback"
      }

      # This will fail to compile if there are syntax errors in the router
      assert {:ok, _pid} =
               MCP.OAuth2.Loopback.start_link(
                 cfg: cfg,
                 base_url: "https://example.com",
                 server_key: "test",
                 state: "state",
                 code_verifier: "verifier",
                 port: 0
               )
    end
  end
end
