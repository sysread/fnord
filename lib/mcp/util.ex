defmodule MCP.Util do
  def debug(msg) do
    if System.get_env("FNORD_DEBUG_MCP") == "1" do
      UI.debug(msg)
    end
  end

  def debug(msg, detail) do
    if System.get_env("FNORD_DEBUG_MCP") == "1" do
      UI.debug(msg, detail)
    end
  end
end
