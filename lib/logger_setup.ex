defmodule LoggerSetup do
  @moduledoc """
  Centralized logger configuration for CLI runs.

  This module selects the destination for Logger output at runtime:
  - When a controlling TTY is available, logs are written to /dev/tty
  - Otherwise, logs are written to standard error (stderr)

  Tests can force a deterministic device by setting a runtime override via
  Services.Globals (see `device_override/0`).
  """

  @spec configure() :: :ok
  def configure do
    # Remove the default handler and replace it with one targeting the chosen device.
    {:ok, handler_config} = :logger.get_handler_config(:default)

    updated_config =
      handler_config
      |> Map.update!(:config, fn cfg ->
        # Keep formatter/template; only the delivery target changes
        # We use the standard logger_std_h when routing to stderr.
        case resolve_device() do
          :stderr -> Map.put(cfg, :type, :standard_error)
          {:tty, _dev} -> cfg
        end
      end)

    # Swap out the default handler first.
    :ok = :logger.remove_handler(:default)

    case resolve_device() do
      :stderr ->
        # Use the standard handler to stderr
        :ok = :logger.add_handler(:default, :logger_std_h, updated_config)

      {:tty, dev} ->
        # Add our custom TTY handler, with the same formatter/template
        # We pass the formatter config as-is; the handler will format with it.
        hcfg = %{
          formatter:
            {Keyword.fetch!(updated_config.config, :formatter),
             Keyword.fetch!(updated_config.config, :formatter_config)}
        }

        # Stash device in process dictionary for the handler to retrieve
        Process.put({__MODULE__, :tty_dev}, dev)

        :ok = :logger.add_handler(:default, UI.TTY.LoggerHandler, hcfg)
    end

    # Ensure a sane default template regardless of handler type
    :ok =
      :logger.update_formatter_config(
        :default,
        :template,
        ["[", :level, "] ", :message, "\n"]
      )

    # Set logger level from env, defaulting to :info
    level =
      case Util.Env.get_env("LOGGER_LEVEL", "info") do
        level when level in ~w[emergency alert critical error warning notice info debug] ->
          String.to_existing_atom(level)

        invalid ->
          IO.warn("Invalid LOGGER_LEVEL '#{invalid}', defaulting to :info")
          :info
      end

    :ok = :logger.set_primary_config(:level, level)
  end

  @doc """
  Resolve the target device.
  - Returns :stderr when no TTY is available or when an override requests stderr
  - Returns {:tty, io_device} when /dev/tty can be opened and no override blocks it
  """
  @spec resolve_device() :: :stderr | {:tty, IO.device()}
  def resolve_device do
    case device_override() do
      :stderr -> :stderr
      :tty -> try_open_tty()
      nil -> try_open_tty()
    end
  end

  @doc """
  Test/runtime override for logger device.
  Supported values via Services.Globals: :stderr | :tty | nil
  """
  @spec device_override() :: :stderr | :tty | nil
  def device_override do
    case Services.Globals.get_env(:fnord, :logger_device_override) do
      v when v in [:stderr, :tty] -> v
      _ -> nil
    end
  end

  @spec try_open_tty() :: :stderr | {:tty, IO.device()}
  defp try_open_tty do
    case File.open("/dev/tty", [:write]) do
      {:ok, dev} -> {:tty, dev}
      {:error, _} -> :stderr
    end
  end
end
