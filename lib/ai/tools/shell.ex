defmodule AI.Tools.Shell do
  @default_timeout_ms 30_000
  @max_timeout_ms 300_000

  @runner """
  #!/bin/sh
  set -euf
  tmp="$1"; shift
  exec "$@" < "$tmp"
  """

  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: false

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def read_args(args), do: {:ok, args}

  @impl AI.Tools
  def ui_note_on_request(%{"commands" => commands, "description" => desc}) do
    command = format_commands(commands)
    {"shell> #{command}", desc}
  end

  def ui_note_on_request(other) do
    {"shell", "Invalid JSON args: #{inspect(other)}"}
  end

  @impl AI.Tools
  def ui_note_on_result(%{"commands" => commands}, result) do
    command = format_commands(commands)
    {"shell> #{command}", result}
  end

  @impl AI.Tools
  def spec do
    allowed =
      Services.Approvals.Shell.preapproved_cmds()
      |> Enum.map(&"- #{&1}")
      |> Enum.join("\n")

    %{
      type: "function",
      function: %{
        name: "shell_tool",
        description: """
        Executes a series of shell commands, each piped to the next, and returns the final output.

        ALWAYS prefer a built-in tool call over this tool when available.

        The user must approve execution of this command before it is run.
        It is essential to remember that you cannot launch interactive commands!
        Commands that require user input or interaction will fail after a timeout, resulting in a poor experience for the user.
        Individual commands may not include redirection, pipes, command substitution, or other complex shell operators.

        Note: There is NO command called "apply_patch" on the system.
              I don't understand why you think there is.

        IMPORTANT: `sed`, `awk`, `find`, and other tools with the potential to
                   modify files ALL require explicit user approval on every
                   invocation. As a rule, if you can use a built-in tool to
                   accomplish the same thing, that is preferable, as the user
                   may not be babysitting this process.

        IMPORTANT: Commands are PIPED (`|`) together! Commands are NOT run
                   sequentially and independently! If you need to run
                   independent commands, you must make multiple tool calls.

        IMPORTANT: This uses elixir's System.cmd/3 to execute commands. It
                   *will* `cd` into the project's source root before executing
                   commands. Some commands DO behave differently without a tty.
                   For example, `rg` REQUIRES a path argument when not run in a
                   tty.

        The following commands are preapproved and will execute without requiring user approval:
        #{allowed}
        """,
        parameters: %{
          type: "object",
          required: ["description", "commands"],
          additionalProperties: false,
          properties: %{
            description: %{
              type: "string",
              description: """
              Explain to the user what the command does and why it is needed.
              This will be displayed to the user in the approval dialog.
              """
            },
            timeout_ms: %{
              type: "integer",
              description: """
              Optional execution timeout in milliseconds.
              Defaults to #{@default_timeout_ms}.
              Must be > 0 and ≤ #{@max_timeout_ms}.
              """
            },
            commands: %{
              type: "array",
              description: """
              A list of commands to execute in sequence, where the output of each command is piped as input to the next.
              Commands are *piped* to each other, NOT run sequentially and independently.
              You must perform multiple too calls to run independent commands.

              Example:

              - Equivalent to `ls -l -a -h | grep some_pattern`:
              ```json
              [
                {"command": "ls", "args": ["-l", "-a", "-h"]},
                {"command": "grep", "args": ["some_pattern"]}
              ]
              ```
              """,
              items: %{
                type: "object",
                description: "An individual command within the overall pipeline.",
                required: ["command", "args"],
                additionalProperties: false,
                properties: %{
                  command: %{
                    type: "string",
                    description: "The base command to execute, without any arguments or options."
                  },
                  args: %{
                    type: "array",
                    description: "A list of arguments and options to pass to the command.",
                    items: %{
                      type: "string",
                      description: """
                      An individual argument or option for the command.
                      This value does not require any special escaping.
                      The code executing it will handle proper shell escaping.
                      Environmental variables (e.g. `$HOME`) will NOT be expanded.
                      """
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(opts) do
    with {:ok, desc} <- AI.Tools.get_arg(opts, "description"),
         {:ok, commands} <- AI.Tools.get_arg(opts, "commands"),
         timeout_ms <- validate_timeout(opts),
         {:ok, commands} <- not_apply_patch(commands),
         {:ok, project} <- Store.get_project(),
         {:ok, :approved} <- confirm(commands, desc),
         {:ok, output} <- run_pipeline(commands, timeout_ms, project.source_root) do
      {:ok, output}
    end
  end

  defp confirm(commands, purpose) do
    Services.Approvals.confirm({commands, purpose}, :shell)
  end

  defp not_apply_patch(commands) do
    with {:ok, json} <- Jason.encode(commands) do
      if String.contains?(json, "apply_patch") do
        {:denied,
         """
         There is no command called `apply_patch` on the system.
         I don't understand why you think there is.
         Use the `file_edit_tool` ffs.
         """}
      else
        {:ok, commands}
      end
    else
      _ -> {:ok, commands}
    end
  end

  defp run_pipeline(commands, timeout_ms, root, input \\ nil)

  defp run_pipeline([], _timeout_ms, _root, input) do
    {:ok, input || "(no output)"}
  end

  defp run_pipeline([command | rest], timeout_ms, root, input) do
    command = special_case(command)

    command
    |> shell_out(timeout_ms, root, input)
    |> case do
      {:ok, {out, 0}} ->
        run_pipeline(rest, timeout_ms, root, out)

      {:ok, {out, code}} ->
        # Some commands exit non-zero even when behaving as expected, like
        # grep. In this case, we still want to return the output, but in a true
        # shell pipeline, it would still stop processing the rest of the
        # commands.
        {:ok,
         """
         Command: #{format_command(command)}
         Exit code: #{code}
         Output:
         #{out}
         """}

      {:error, :not_found} ->
        {:ok, "Command not found: #{command["command"]}"}

      {:error, :timeout} ->
        {:ok,
         """
         Command: #{format_command(command)}
         Error: timed out after #{timeout_ms} ms

         Remember that interactive commands will always time out.
         Some commands behave differently outside of an interactive shell.
         For example, `rg` REQUIRES a path argument when not run within a tty.
         """}
    end
  end

  defp shell_out(%{"command" => command, "args" => args}, timeout_ms, root, nil) do
    command
    |> System.find_executable()
    |> case do
      nil ->
        {:error, :not_found}

      path ->
        run_with_timeout(timeout_ms, fn ->
          {:ok, System.cmd(path, args, cd: root, stderr_to_stdout: true)}
        end)
    end
  end

  defp shell_out(%{"command" => command, "args" => args}, timeout_ms, root, stdin) do
    with {:ok, tmp} <- Briefly.create(),
         :ok <- File.write(tmp, stdin, [:binary]),
         :ok <- chmod_600(tmp),
         {:ok, runner} <- Briefly.create(),
         :ok <- File.write(runner, @runner),
         :ok <- File.chmod(runner, 0o700) do
      run_with_timeout(
        timeout_ms,
        fn ->
          try do
            {:ok, System.cmd(runner, [tmp, command | args], cd: root, stderr_to_stdout: true)}
          after
            # normal completion cleanup
            File.rm(tmp)
            File.rm(runner)
          end
        end,
        on_timeout: fn ->
          # timeout cleanup fallback
          File.rm(tmp)
          File.rm(runner)
        end
      )
    end
  end

  # -----------------------------------------------------------------------------
  # LLMs *love* `rg`, but they often forget to provide a path argument, even
  # when it's explicitly called out in the tool spec. This special case adds
  # the project's source_root as a path argument if no other path-like
  # arguments are provided. If the LLM provides a pattern arg that *looks* like
  # a path, and no other path-like args, we can't do anything sensible, since
  # we don't know *which* arg they borked, so we just let the command fail.
  # -----------------------------------------------------------------------------
  defp special_case(%{"command" => "rg", "args" => args} = cmd) do
    args
    # Filter out options, leaving only positional args
    |> Enum.filter(fn arg -> not String.starts_with?(arg, "-") end)
    # See if any of the positional args look like a path (contain a dot or slash)
    |> Enum.filter(fn arg -> String.starts_with?(arg, ".") or String.starts_with?(arg, "/") end)
    # If no positional args look like a path, add the project's source_root to search current dir
    |> case do
      # None found.
      [] ->
        with {:ok, project} <- Store.get_project() do
          %{"command" => "rg", "args" => args ++ [project.source_root]}
        else
          # This shouldn't be possible, but if it does happen, just return as-is
          _ -> cmd
        end

      _ ->
        cmd
    end
  end

  defp special_case(cmd), do: cmd

  defp chmod_600(path) do
    # Ensure stdin temp is not world/group readable regardless of umask
    File.chmod(path, 0o600)
  end

  defp run_with_timeout(timeout, fun, opts \\ []) do
    on_timeout = Keyword.get(opts, :on_timeout, fn -> :ok end)
    task = Task.async(fn -> fun.() end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        # task did not respond, was force-killed
        on_timeout.()
        {:error, :timeout}

      {:exit, _reason} ->
        on_timeout.()
        {:error, :timeout}
    end
  end

  defp validate_timeout(opts) do
    val = Map.get(opts, "timeout_ms", @default_timeout_ms)

    cond do
      !is_integer(val) -> @default_timeout_ms
      val <= 0 -> @default_timeout_ms
      val > @max_timeout_ms -> @max_timeout_ms
      true -> val
    end
  end

  defp format_commands(commands) do
    commands
    |> Enum.map(&format_command/1)
    |> Enum.join(" | ")
  end

  defp format_command(%{"command" => command, "args" => args}) do
    [command | args]
    |> Enum.join(" ")
  end
end
