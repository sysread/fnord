defmodule UI.TTY.LoggerHandler do
  @moduledoc """
  Erlang `:logger` handler that writes formatted logs to /dev/tty when available.

  This handler expects its config to include:
  - `:formatter` => {formatter_mod, formatter_config}

  On each log event, it attempts to open `/dev/tty` for writing. If that fails,
  it falls back to standard error.
  """

  @spec log(:logger.log_event(), :logger.handler_config()) :: :ok
  def log(log_event, %{formatter: {formatter_mod, formatter_config}}) do
    formatted = formatter_mod.format(log_event, formatter_config)
    bin = IO.iodata_to_binary(formatted)

    case File.open("/dev/tty", [:write]) do
      {:ok, tty} ->
        try do
          IO.binwrite(tty, bin)
        after
          File.close(tty)
        end

        :ok

      {:error, _} ->
        :io.format(:standard_error, ~c"~s", [bin])
        :ok
    end
  end
end
