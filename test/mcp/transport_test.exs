defmodule MCP.TransportTest do
  use Fnord.TestCase, async: true

  # Reconstructs the URL Hermes will actually request: it runs base_url
  # through URI.new!/1 and then URI.append_path(base_url, mcp_path). The
  # assertions below pin the *effective* URL, not the opts shape, because
  # that composition is where the trailing-slash mangling bug lived.
  defp effective_url(opts) do
    opts[:base_url]
    |> URI.new!()
    |> URI.append_path(opts[:mcp_path])
    |> URI.to_string()
  end

  describe "map/2 for http transport endpoint URL" do
    test "base_url carrying the endpoint path is requested verbatim" do
      cfg = %{"transport" => "http", "base_url" => "https://mcp.linear.app/mcp"}

      assert {:streamable_http, opts} = MCP.Transport.map("linear", cfg)
      assert opts[:base_url] == "https://mcp.linear.app"
      assert opts[:mcp_path] == "/mcp"
      assert effective_url(opts) == "https://mcp.linear.app/mcp"
    end

    test "explicit mcp_path keeps Hermes append semantics" do
      cfg = %{
        "transport" => "http",
        "base_url" => "https://example.run.app",
        "mcp_path" => "/mcp"
      }

      assert {:streamable_http, opts} = MCP.Transport.map("srv", cfg)
      assert opts[:base_url] == "https://example.run.app"
      assert opts[:mcp_path] == "/mcp"
      assert effective_url(opts) == "https://example.run.app/mcp"
    end

    test "bare origin with no mcp_path requests the root path" do
      cfg = %{"transport" => "http", "base_url" => "https://example.com"}

      assert {:streamable_http, opts} = MCP.Transport.map("srv", cfg)
      assert effective_url(opts) == "https://example.com/"
    end

    test "deep endpoint path survives the split" do
      cfg = %{"transport" => "http", "base_url" => "https://example.com/api/v1/mcp"}

      assert {:streamable_http, opts} = MCP.Transport.map("srv", cfg)
      assert effective_url(opts) == "https://example.com/api/v1/mcp"
    end
  end
end
