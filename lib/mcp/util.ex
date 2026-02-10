defmodule MCP.Util do
  @moduledoc false

  defp debug_enabled? do
    Util.Env.mcp_debug_enabled?()
  end

  def debug(msg) do
    if debug_enabled?() do
      UI.debug(msg)
    end
  end

  def debug(msg, detail) do
    if debug_enabled?() do
      UI.debug(msg, detail)
    end
  end
end
