defmodule Watch do
  @moduledoc """
  Watch a directory for changes and run the fnord index command when changes
  are detected.
  """

  def run(opts) do
    with :ok <- check_dependencies() do
      cmd("watchman", ["watch", opts.directory])
      cmd("watchman", ["--log-level", "info"])

      IO.puts("Watching #{opts.directory} for changes")
      setup_trigger(opts.directory, opts.project)

      IO.puts("Press Ctrl+C to stop watching")
      wait_for_changes()
    end
  end

  defp cmd(command, args) do
    IO.puts("> #{command} #{Enum.join(args, " ")}")
    System.cmd(command, args, stderr_to_stdout: true)
  end

  defp shell(command) do
    IO.puts("> #{command}")
    System.shell(command)
  end

  defp check_dependencies do
    case System.find_executable("watchman") do
      nil -> {:error, "Watchman is required to run this module. Please install it and try again."}
      _ -> :ok
    end
  end

  defp setup_trigger(directory, project) do
    command_json =
      Jason.encode!([
        "trigger",
        directory,
        %{
          "name" => "fnord-trigger",
          "expression" => ["true"],
          "command" => ["fnord", "index", "-p", project, "-d", directory],
          "settle" => 5_000
        }
      ])

    shell("watchman -j <<EOF\n#{command_json}\nEOF")
  end

  defp wait_for_changes do
    log_path =
      cmd("watchman", ["get-log"])
      |> elem(0)
      |> Jason.decode!()
      |> get_in(["log"])

    IO.puts("> tail -f #{log_path}")

    # Open a port to execute `tail -f` and stream the output to the console
    port =
      Port.open({:spawn_executable, System.find_executable("tail")}, [
        :exit_status,
        :stderr_to_stdout,
        :stream,
        args: ["-f", log_path]
      ])

    # Continuously read from the port and print output to the console
    listen_to_port(port)
  end

  defp listen_to_port(port) do
    receive do
      {^port, {:data, data}} ->
        IO.write(data)
        listen_to_port(port)

      {^port, {:exit_status, status}} ->
        IO.puts("tail process exited with status: #{status}")
    end
  end
end
