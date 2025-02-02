defmodule Fnord do
  @moduledoc """
  Fnord is a code search tool that uses OpenAI's embeddings API to index and
  search code files.
  """

  @desc "fnord - an AI powered, conversational interface for your project that learns"

  @doc """
  Main entry point for the application. Parses command line arguments and
  dispatches to the appropriate subcommand.
  """
  def main(args) do
    {:ok, _} = Application.ensure_all_started(:briefly)

    configure_logger()

    with {:ok, subcommand, opts, unknown} <- parse_options(args) do
      opts = set_globals(opts)

      subcommand
      |> to_module_name()
      |> apply(:run, [opts, unknown])
    else
      {:error, reason} -> IO.puts("Error: #{reason}")
    end
  end

  def spec() do
    [
      name: "fnord",
      description: @desc,
      allow_unknown_args: false,
      version: get_version(),
      subcommands:
        [
          Cmd.Ask,
          Cmd.Conversations,
          Cmd.Defrag,
          Cmd.Files,
          Cmd.Index,
          Cmd.Notes,
          Cmd.Projects,
          Cmd.Replay,
          Cmd.Search,
          Cmd.ShellCompletion,
          Cmd.Summary,
          Cmd.Tool,
          Cmd.Torch,
          Cmd.Upgrade
        ]
        |> Enum.flat_map(& &1.spec())
    ]
  end

  defp parse_options(args) do
    parser = spec() |> Optimus.new!()

    with {[subcommand], result} <- Optimus.parse!(parser, args) do
      options =
        result.args
        |> Map.merge(result.options)
        |> Map.merge(result.flags)

      {:ok, subcommand, options, result.unknown}
    else
      _ -> {:error, "missing or unknown subcommand"}
    end
  end

  defp get_version do
    {:ok, vsn} = :application.get_key(:fnord, :vsn)
    to_string(vsn)
  end

  def configure_logger do
    {:ok, handler_config} = :logger.get_handler_config(:default)
    updated_config = Map.update!(handler_config, :config, &Map.put(&1, :type, :standard_error))

    :ok = :logger.remove_handler(:default)
    :ok = :logger.add_handler(:default, :logger_std_h, updated_config)

    :ok =
      :logger.update_formatter_config(
        :default,
        :template,
        ["[", :level, "] ", :message, "\n"]
      )

    logger_level =
      System.get_env("LOGGER_LEVEL", "info")
      |> String.to_existing_atom()

    :ok = :logger.set_primary_config(:level, logger_level)
  end

  defp set_globals(args) do
    args
    |> Enum.each(fn
      {:workers, workers} -> Application.put_env(:fnord, :workers, workers)
      {:project, project} -> Application.put_env(:fnord, :project, project)
      {:quiet, quiet} -> Application.put_env(:fnord, :quiet, quiet)
      _ -> :ok
    end)

    # --------------------------------------------------------------------------
    # When not connected to a TTY, the --quiet flag is automatically enabled,
    # unless the user explicitly specifies it.
    # --------------------------------------------------------------------------
    cond do
      args[:quiet] -> args
      IO.ANSI.enabled?() -> args
      true -> Map.put(args, :quiet, true)
    end
  end

  defp to_module_name(subcommand) do
    submodule =
      subcommand
      |> Atom.to_string()
      |> Macro.camelize()

    Module.concat("Cmd", submodule)
  end
end
