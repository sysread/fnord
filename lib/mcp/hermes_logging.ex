defmodule MCP.HermesLogging do
  @moduledoc """
  Integration point for configuring Hermes MCP logging.

  Hermes logs MCP client/server/transport/protocol events via `Logger.*`.
  When `LOGGER_LEVEL=debug`, those logs can be very noisy unless explicitly
  disabled.

  Fnord treats Hermes MCP debug logs as opt-in: they are enabled only when
  `FNORD_DEBUG_MCP` is truthy.

  This module centralizes that behavior so it can be applied early (before
  any MCP clients start) and consistently across call sites.
  """

  @doc """
  Integration point for configuring Hermes MCP logging.
  Configures Hermes MCP logging based on `FNORD_DEBUG_MCP`.
  Must be called before MCP clients start to prevent Hermes default debug logging when LOGGER_LEVEL=debug.
  Sets `:hermes_mcp, :log` and `:hermes_mcp, :logging` application env keys.
  """
  @spec configure() :: :ok
  def configure do
    mcp_debug_enabled = Util.Env.mcp_debug_enabled?()

    log_level =
      case mcp_debug_enabled do
        true -> :debug
        false -> :error
      end

    # Hermes' logger wrapper checks this flag before emitting anything.
    Application.put_env(:hermes_mcp, :log, mcp_debug_enabled)

    Application.put_env(:hermes_mcp, :logging,
      client_events: log_level,
      server_events: log_level,
      transport_events: log_level,
      protocol_messages: log_level
    )

    :ok
  end
end
