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
    configure_logger()

    {:ok, _} = Application.ensure_all_started(:briefly)
    Once.start_link([])
    NotesServer.start_link([])

    with {:ok, [command | subcommands], opts, unknown} <- parse_options(args) do
      opts = set_globals(opts)
      cmd_module = to_module_name(command)

      # Require a project if the command needs it. As a rule, we make the
      # project option optional in the Cmd implementation, and then manually
      # require it here. That allows us to default to the project associated
      # with the current directory, if possible.
      if cmd_module.requires_project?() && !Settings.project_is_set?() do
        IO.puts(:stderr, """
        Error: The command `#{command}` must be called from an indexed project directory or with the --project option set to an indexed project.
        """)

        exit({:shutdown, 1})
      end

      # While the subcommand is working, we can check for a new version in the
      # background.
      version_check_task =
        if command == :upgrade do
          nil
        else
          Task.async(fn -> Util.get_latest_version() end)
        end

      # Run the subcommand
      Cmd.perform_command(cmd_module, opts, subcommands, unknown)

      # Once the command has finished, we can check if a new version is
      # available and prompt the user to upgrade if there is.
      if !is_nil(version_check_task) do
        with {:ok, {:ok, latest}} <- Task.yield(version_check_task, 1000) do
          current = Util.get_running_version()

          if Version.compare(current, latest) == :lt do
            IO.puts(:stderr, """

            A new version of fnord is available! To upgrade to v#{latest}:

                fnord upgrade
            """)
          end
        end
      end
    end
  end

  def spec() do
    subcommands = [
      Cmd.Ask,
      Cmd.Config,
      Cmd.Conversations,
      Cmd.Files,
      Cmd.Frobs,
      Cmd.Index,
      Cmd.Notes,
      Cmd.Prime,
      Cmd.Projects,
      Cmd.Replay,
      Cmd.Search,
      Cmd.Summary,
      Cmd.Tool,
      Cmd.Torch,
      Cmd.Upgrade
    ]

    [
      name: "fnord",
      description: @desc,
      version: Util.get_running_version(),
      subcommands: Enum.flat_map(subcommands, & &1.spec())
    ]
  end

  defp parse_options(args) do
    spec()
    |> Optimus.new!()
    |> Optimus.parse!(args)
    |> case do
      {subcommand, %Optimus.ParseResult{} = result} ->
        {:ok, subcommand, merge_options(result), result.unknown}

      # If no subcommand is specified, fail.
      _ ->
        {:error, :no_subcommand}
    end
  end

  defp merge_options(optimus_result) do
    optimus_result.args
    |> Map.merge(optimus_result.options)
    |> Map.merge(optimus_result.flags)
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

  defp to_module_name(subcommand) do
    submodule =
      subcommand
      |> Atom.to_string()
      |> Macro.camelize()

    Module.concat("Cmd", submodule)
  end

  defp set_globals(args) do
    args
    |> Enum.each(fn
      {:workers, workers} ->
        Application.put_env(:fnord, :workers, workers)

      {:quiet, quiet} ->
        Application.put_env(:fnord, :quiet, quiet)

      {:project, project} when is_binary(project) ->
        Settings.set_project(project)

      _ ->
        :ok
    end)

    # --------------------------------------------------------------------------
    # If the user did not specify a project in ARGV, we try to set it based on
    # the current working directory.
    # --------------------------------------------------------------------------
    unless Settings.project_is_set?() do
      with {:ok, project} <- get_project_from_cwd() do
        UI.debug("Project not specified, but CWD is within recognized project: #{project}")
        Settings.set_project(project)
      end
    end

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

  @spec get_project_from_cwd() :: {:ok, binary} | {:error, :not_in_project}
  defp get_project_from_cwd() do
    # Map project roots to project names.
    projects =
      Settings.new()
      |> Map.get(:data, %{})
      |> Enum.map(fn {k, %{"root" => root}} -> {root, k} end)
      |> Map.new()

    with {:ok, cwd} <- File.cwd(),
         root <- Path.expand(cwd),
         {:ok, project} <- Map.fetch(projects, root) do
      {:ok, project}
    else
      _ -> {:error, :not_in_project}
    end
  end
end
