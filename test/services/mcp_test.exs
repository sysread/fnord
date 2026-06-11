defmodule Services.MCPTest do
  # async: false - the supervisor-detachment test registers the real,
  # VM-globally named MCP.Supervisor.
  use Fnord.TestCase, async: false

  import ExUnit.CaptureLog

  # ---------------------------------------------------------------------------
  # Server configs are written to the real per-test settings file; only the
  # Hermes runtime is scripted, through the MCP.Client facade. Credentials for
  # the auth-status checks are real files under the per-test HOME.
  # ---------------------------------------------------------------------------

  @stdio_cfg %{"transport" => "stdio", "command" => "echo", "args" => []}

  @oauth_cfg %{
    "transport" => "stdio",
    "command" => "echo",
    "args" => [],
    "oauth" => %{
      "discovery_url" => "https://example.com/.well-known/oauth-authorization-server",
      "client_id" => "c",
      "scopes" => ["openid"]
    }
  }

  defp add_server(name, cfg \\ @stdio_cfg) do
    {:ok, _settings} = Settings.MCP.add_server(Settings.new(), :global, name, cfg)
    :ok
  end

  test "test/0 assembles status for connected servers" do
    mock_mcp_client()
    add_server("srv1")
    add_server("srv2")

    Mox.stub(MCP.Client.Mock, :connected?, fn _server -> true end)

    Mox.stub(MCP.Client.Mock, :list_tools, fn _server ->
      {:ok, [%{"name" => "toolX", "description" => "descX"}]}
    end)

    Mox.stub(MCP.Client.Mock, :get_server_capabilities, fn _server ->
      {:ok, %{"tools" => %{}}}
    end)

    assert %{status: "ok", servers: servers} = Services.MCP.test()

    for srv <- ["srv1", "srv2"] do
      assert %{
               status: "ok",
               server_info: %{"name" => name, "status" => "running"},
               capabilities: %{"tools" => %{}},
               tools_count: 1,
               has_oauth: false
             } = servers[srv]

      assert name == "#{srv}-server"
    end
  end

  test "test/0 reports per-server error when the client is not connected" do
    mock_mcp_client()
    add_server("srv1")

    # The facade passthrough resolves to the real Default, which finds no
    # client process registered for "srv1" - the genuine disconnected state.
    assert %{status: "ok", servers: %{"srv1" => data}} = Services.MCP.test()

    assert data.status == "error"
    assert data.error == ":not_started"
    assert data.capabilities == %{}
    assert data.tools_count == 0
  end

  describe "oauth auth status" do
    setup do
      mock_mcp_client()
      add_server("srv1", @oauth_cfg)
      :ok
    end

    test "valid when stored credentials have an unexpired token" do
      now = System.os_time(:second)

      :ok =
        MCP.OAuth2.CredentialsStore.write("srv1", %{
          "access_token" => "at",
          "expires_at" => now + 600
        })

      assert %{servers: %{"srv1" => data}} = Services.MCP.test()
      assert data.has_oauth == true
      assert data.auth_status == :valid
    end

    test "expired when the stored token is past expiry" do
      now = System.os_time(:second)

      :ok =
        MCP.OAuth2.CredentialsStore.write("srv1", %{
          "access_token" => "at",
          "expires_at" => now - 600
        })

      assert %{servers: %{"srv1" => data}} = Services.MCP.test()
      assert data.auth_status == :expired
    end

    test "missing when no credentials are stored" do
      assert %{servers: %{"srv1" => data}} = Services.MCP.test()
      assert data.has_oauth == true
      assert data.auth_status == :missing
    end
  end

  test "supervisor survives the process that started it" do
    # The Hermes stack must outlive whichever process happened to trigger MCP
    # startup. Settings are empty here, so the real supervisor boots with zero
    # children - safe, but VM-globally named, hence async: false and cleanup.
    on_exit(fn ->
      case Process.whereis(MCP.Supervisor) do
        nil -> :ok
        pid -> Supervisor.stop(pid, :normal)
      end
    end)

    test_pid = self()

    {pid, ref} =
      spawn_monitor(fn ->
        :ok = MCP.Client.Default.start_supervisor()
        send(test_pid, :started)

        receive do
          :never -> :ok
        end
      end)

    assert_receive :started, 5000

    # A brutal kill propagates through any surviving link; the supervisor
    # must not go down with its initiator.
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2000

    sup = Process.whereis(MCP.Supervisor)
    assert is_pid(sup)
    assert Process.alive?(sup)
  end

  test "suppresses Hermes MCP debug logs unless FNORD_DEBUG_MCP is set" do
    original_level = :logger.get_primary_config() |> Map.fetch!(:level)
    original_debug_var = System.get_env("FNORD_DEBUG_MCP")
    original_hermes_log = Application.get_env(:hermes_mcp, :log)
    original_hermes_logging = Application.get_env(:hermes_mcp, :logging)

    on_exit(fn ->
      :logger.set_primary_config(:level, original_level)

      case original_debug_var do
        nil -> System.delete_env("FNORD_DEBUG_MCP")
        val -> System.put_env("FNORD_DEBUG_MCP", val)
      end

      case original_hermes_log do
        nil -> Application.delete_env(:hermes_mcp, :log)
        val -> Application.put_env(:hermes_mcp, :log, val)
      end

      case original_hermes_logging do
        nil -> Application.delete_env(:hermes_mcp, :logging)
        val -> Application.put_env(:hermes_mcp, :logging, val)
      end
    end)

    :logger.set_primary_config(:level, :debug)
    Util.Env.delete_env("FNORD_DEBUG_MCP")

    log =
      capture_log(fn ->
        Services.MCP.start()
        Process.sleep(200)
      end)

    refute String.contains?(log, "MCP client event")
    refute String.contains?(log, "[MCP message]")
  end
end
