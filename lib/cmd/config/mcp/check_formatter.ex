defmodule Cmd.Config.MCP.CheckFormatter do
  @moduledoc """
  Formats MCP check results in a human-friendly format with checkmarks.
  """

  @doc """
  Formats the test results from Services.MCP.test/1 into human-readable output.
  """
  @spec format_results(map()) :: :ok
  def format_results(%{servers: servers}) when map_size(servers) == 0 do
    UI.puts("Checking MCP servers...")
    UI.puts("")
    UI.puts("No MCP servers configured")
    :ok
  end

  def format_results(%{servers: servers}) do
    UI.puts("Checking MCP servers...")
    UI.puts("")

    servers
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.each(fn {name, data} ->
      format_server(name, data)
      UI.puts("")
    end)

    :ok
  end

  defp format_server(name, data) do
    # Server name with OAuth indicator if present
    server_label =
      if data[:has_oauth] do
        "#{name} (OAuth)"
      else
        name
      end

    UI.puts(IO.ANSI.format([:bright, server_label, :reset], UI.colorize?()))

    # Connection status
    format_connection_status(data)

    # Authentication status
    format_auth_status(data)

    # Tools status
    format_tools_status(data)

    # Capabilities status
    format_capabilities_status(data)

    # If we have tools, show the list (detailed list only shown when FNORD_DEBUG_MCP=1)
    case data do
      %{tools: tools} when is_list(tools) and length(tools) > 0 ->
        UI.newline()
        format_tools_list(tools)

      %{tools_count: count, tools_hint: hint} when is_integer(count) ->
        # Show concise hint about tool count and how to enable details
        if count > 0 do
          UI.newline()
          UI.puts("  Available tools: (#{count} available) — #{hint}")
        else
          UI.newline()
          UI.puts("  Available tools: (none) — #{hint}")
        end

      _ ->
        :ok
    end

    # If authentication is a problem, suggest login
    case data do
      %{auth_status: status} when status in [:missing, :expired] ->
        UI.puts("")
        UI.puts(IO.ANSI.format([:cyan, "  fnord config mcp login #{name}"], UI.colorize?()))

      _ ->
        :ok
    end
  end

  defp format_connection_status(%{status: "ok"}) do
    UI.puts("  #{success_symbol()} Connection")
  end

  defp format_connection_status(%{status: "error", error: error}) do
    UI.puts("  #{error_symbol()} Connection #{format_error_detail(error)}")
  end

  defp format_connection_status(_) do
    UI.puts("  #{error_symbol()} Connection (unknown)")
  end

  defp format_auth_status(%{has_oauth: true, auth_status: :valid}) do
    UI.puts("  #{success_symbol()} Authentication")
  end

  defp format_auth_status(%{has_oauth: true, auth_status: :expired}) do
    UI.puts("  #{warning_symbol()} Authentication (expired)")
  end

  defp format_auth_status(%{has_oauth: true, auth_status: :missing}) do
    UI.puts("  #{error_symbol()} Authentication (no credentials)")
  end

  defp format_auth_status(%{has_oauth: false}) do
    UI.puts("  #{na_symbol()} Authentication (N/A)")
  end

  defp format_auth_status(_) do
    UI.puts("  #{na_symbol()} Authentication (N/A)")
  end

  defp format_tools_status(%{status: "error"}) do
    UI.puts("  #{na_symbol()} Tools (unavailable)")
  end

  defp format_tools_status(%{tools: tools}) when is_list(tools) do
    count = length(tools)

    if count > 0 do
      UI.puts("  #{success_symbol()} Tools (#{count} available)")
    else
      UI.puts("  #{warning_symbol()} Tools (none)")
    end
  end

  defp format_tools_status(%{tools_count: count}) when is_integer(count) do
    if count > 0 do
      UI.puts("  #{success_symbol()} Tools (#{count} available)")
    else
      UI.puts("  #{warning_symbol()} Tools (none)")
    end
  end

  defp format_tools_status(_) do
    UI.puts("  #{na_symbol()} Tools (unavailable)")
  end

  defp format_capabilities_status(%{status: "error"}) do
    UI.puts("  #{na_symbol()} Capabilities (unavailable)")
  end

  defp format_capabilities_status(%{capabilities: caps}) when is_map(caps) do
    cap_names =
      caps
      |> Enum.filter(fn {_k, v} -> v end)
      |> Enum.map(fn {k, _v} -> k end)
      |> Enum.sort()

    if length(cap_names) > 0 do
      caps_str = Enum.join(cap_names, ", ")
      UI.puts("  #{success_symbol()} Capabilities (#{caps_str})")
    else
      UI.puts("  #{warning_symbol()} Capabilities (none)")
    end
  end

  defp format_capabilities_status(_) do
    UI.puts("  #{na_symbol()} Capabilities (unavailable)")
  end

  defp format_tools_list(tools) do
    UI.puts("  Available tools:")

    Enum.each(tools, fn tool ->
      name = tool["name"] || "(unnamed)"
      desc = tool["description"] || ""

      if desc != "" do
        UI.puts("    • #{name} - #{desc}")
      else
        UI.puts("    • #{name}")
      end
    end)
  end

  defp format_error_detail(error) when is_binary(error) do
    "(#{error})"
  end

  defp format_error_detail(error) do
    "(#{inspect(error)})"
  end

  defp success_symbol do
    IO.ANSI.format([:green, "✓", :reset], UI.colorize?())
  end

  defp error_symbol do
    IO.ANSI.format([:red, "✗", :reset], UI.colorize?())
  end

  defp warning_symbol do
    IO.ANSI.format([:yellow, "⚠", :reset], UI.colorize?())
  end

  defp na_symbol do
    IO.ANSI.format([:light_black, "-", :reset], UI.colorize?())
  end
end
