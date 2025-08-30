defmodule MCP.FnordClient do
  @moduledoc false

  use Hermes.Client,
    name: "fnord",
    version: Util.get_running_version(),
    protocol_version: "2024-11-05",
    capabilities: [:roots]
end
