defmodule UI.Tee.LoggerHandler do
  @moduledoc """
  Erlang `:logger` handler that mirrors log messages to the tee file.

  Installed as the `:tee` handler when `--tee` is active. Uses the same
  template as the default handler so the transcript reads like normal log
  output, minus ANSI codes (stripping happens in `UI.Tee.write/1`).
  """

  # ---------------------------------------------------------------------------
  # Erlang logger handler callback
  # ---------------------------------------------------------------------------

  # Called by Erlang's logger framework for each log event. The config map
  # includes a :formatter key with {module, formatter_config} for formatting
  # the log event into iodata.
  @spec log(:logger.log_event(), :logger.handler_config()) :: :ok
  def log(log_event, %{formatter: {formatter_mod, formatter_config}}) do
    formatted = formatter_mod.format(log_event, formatter_config)
    UI.Tee.write(formatted)
  end
end
