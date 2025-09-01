defmodule MCP.FnordClient do
  @moduledoc false

  use Hermes.Client,
    name: "fnord",
    version: "1.0.0",
    protocol_version: "2025-03-26",
    capabilities: [:roots]
end
