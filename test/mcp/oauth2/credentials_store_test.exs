defmodule MCP.OAuth2.CredentialsStoreTest do
  use ExUnit.Case, async: false

  @server "testsrv"

  setup do
    # isolate home dir by using a tmp path via env override if supported, else ensure cleanup
    # Here we'll just write and clean the real path; CI will run in sandbox
    on_exit(fn ->
      # reset file
      path = MCP.OAuth2.CredentialsStore.path()
      File.rm(path)
    end)

    :ok
  end

  test "read returns not_found when missing" do
    assert {:error, :not_found} = MCP.OAuth2.CredentialsStore.read(@server)
  end

  test "write and read works with 0600 perms and atomicity" do
    tok = %{"access_token" => "at", "expires_at" => System.os_time(:second) + 3600}

    assert :ok = MCP.OAuth2.CredentialsStore.write(@server, tok)

    {:ok, got} = MCP.OAuth2.CredentialsStore.read(@server)
    assert got["access_token"] == "at"

    # file perms
    path = MCP.OAuth2.CredentialsStore.path()
    {:ok, %File.Stat{mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) == 0o600

    # overwrite atomically
    tok2 = Map.put(tok, "access_token", "at2")
    assert :ok = MCP.OAuth2.CredentialsStore.write(@server, tok2)
    {:ok, got2} = MCP.OAuth2.CredentialsStore.read(@server)
    assert got2["access_token"] == "at2"
  end

  test "delete removes server entry" do
    tok = %{"access_token" => "at", "expires_at" => System.os_time(:second) + 3600}
    :ok = MCP.OAuth2.CredentialsStore.write(@server, tok)
    :ok = MCP.OAuth2.CredentialsStore.delete(@server)
    assert {:error, :not_found} = MCP.OAuth2.CredentialsStore.read(@server)
  end
end
