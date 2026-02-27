defmodule Fnord do
  @moduledoc """
  Fnord is a code search tool that uses OpenAI's embeddings API to index and
  search code files.
  """

  @desc "fnord - an AI code archaeologist"

  # HTTP pool sizes are fixed based on the expected concurrency profile of
  # each subsystem. The API pool handles the coordinator's LLM calls; the
  # others handle background work that should not compete with the
  # coordinator for connections.
  @pool_api 12
  @pool_indexer 6
  @pool_memory 6
  @pool_notes 6

  @doc """
  Main entry point for the application. Parses command line arguments and
  dispatches to the appropriate subcommand.
  """
  def main(args) do
    configure_logger()

    Services.start_all()

    # Load all frob modules to prevent race conditions during concurrent operations
    Frobs.load_all_modules()

    # Parse command line arguments
    with {:ok, [command | subcommands], opts, unknown} <- parse_options(args) do
      # Certain options are common to most, if not all, subcommands, and control
      # global state (e.g. project, verbosity).
      opts = set_globals(opts)

      cmd_module = to_module_name(command)

      # -------------------------------------------------------------------------
      # HTTP Pools
      # -------------------------------------------------------------------------
      :hackney_pool.start_pool(:ai_api, max_connections: @pool_api)
      :hackney_pool.start_pool(:ai_indexer, max_connections: @pool_indexer)
      :hackney_pool.start_pool(:ai_memory, max_connections: @pool_memory)
      :hackney_pool.start_pool(:ai_notes, max_connections: @pool_notes)

      # Start services that depend on CLI configuration now that it's available.
      # These services depend on settings parsed from CLI arguments in set_globals().
      Services.start_config_dependent_services(command)

      # Require a project if the command needs it. As a rule, we make the
      # project option optional in the Cmd implementation, and then manually
      # require it here. That allows us to default to the project associated
      # with the current directory, if possible.
      if cmd_module.requires_project?() && !Settings.project_is_set?() do
        UI.fatal("""
        Error: The command `#{command}` must be called from an indexed project directory or with the --project option set to an indexed project.
        """)

        exit({:shutdown, 1})
      end

      # While the subcommand is working, we can check for a new version in the
      # background (unless we're running the upgrade command itself).
      maybe_start_version_check(command)

      # Run the subcommand
      Cmd.perform_command(cmd_module, opts, subcommands, unknown)

      # Once the command has finished, we can check if a new version is
      # available and prompt the user to upgrade if there is.
      maybe_show_version_notification(command)
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
      Cmd.Memory,
      Cmd.Replay,
      Cmd.Search,
      Cmd.Summary,
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

  @spec parse_options([String.t()]) ::
          {:ok, [atom()], map(), [String.t()]} | {:error, :no_subcommand}
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
      case Util.Env.get_env("LOGGER_LEVEL", "info") do
        level when level in ~w[emergency alert critical error warning notice info debug] ->
          String.to_existing_atom(level)

        invalid ->
          IO.warn("Invalid LOGGER_LEVEL '#{invalid}', defaulting to :info")
          :info
      end

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
      {:quiet, quiet} ->
        Settings.set_quiet(quiet)

      {:project, project} when is_binary(project) ->
        Settings.set_project(project)

      {:edit, edit_mode} ->
        Settings.set_edit_mode(edit_mode)

      {:yes, v} when is_integer(v) ->
        Settings.set_auto_approve(v > 0)
        Settings.set_yes_count(v)

      {:yes, v} when is_boolean(v) ->
        Settings.set_auto_approve(v)
        Settings.set_yes_count(if v, do: 1, else: 0)

      {:fonz, val} ->
        Settings.set_fonz_mode(!!val)

      _ ->
        :ok
    end)

    # --------------------------------------------------------------------------
    # If the user did not specify a project in ARGV, resolve it via ResolveProject.
    # --------------------------------------------------------------------------
    unless Settings.project_is_set?() do
      case ResolveProject.resolve(nil) do
        {:ok, project} ->
          UI.info("Project not specified, but resolved to #{project}")
          Settings.set_project(project)

        {:error, :not_in_project} ->
          :ok
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

  # Start background version check unless running upgrade command
  # Dialyzer can't infer that command is a dynamic atom from CLI args
  @dialyzer {:no_match, maybe_start_version_check: 1}
  @spec maybe_start_version_check(atom()) :: :ok
  defp maybe_start_version_check(:upgrade), do: :ok

  defp maybe_start_version_check(_command) do
    task = Services.Globals.Spawn.async(fn -> Util.get_latest_version() end)
    Process.put(:version_check_task, task)
    :ok
  end

  # Show version notification if available
  # Dialyzer can't infer that command is a dynamic atom from CLI args
  @dialyzer {:no_match, maybe_show_version_notification: 1}
  @spec maybe_show_version_notification(atom()) :: :ok
  defp maybe_show_version_notification(:upgrade), do: :ok

  defp maybe_show_version_notification(_command) do
    case Process.get(:version_check_task) do
      nil ->
        :ok

      task ->
        with {:ok, {:ok, latest}} <- Task.yield(task, 1000) do
          current = Util.get_running_version()

          if Version.compare(current, latest) == :lt do
            UI.info("""

            A new version of fnord is available! To upgrade to v#{latest}:

                fnord upgrade
            """)
          end
        end
    end
  end
end
