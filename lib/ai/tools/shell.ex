defmodule AI.Tools.Shell do
  @moduledoc """
  A tool for executing shell commands with user approval.

  Delegates command approval logic to Services.Approvals, which provides
  hierarchical approval scopes (session, project, global) with persistence.
  Commands are parsed into approval bits that allow for granular approval
  of command families and subcommands.
  """

  @default_timeout_ms 30_000
  @max_timeout_ms 300_000

  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: false

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def read_args(args), do: {:ok, args}

  @impl AI.Tools
  def ui_note_on_request(%{"command" => cmd, "description" => desc}) do
    {"shell> #{cmd}", desc}
  end

  @impl AI.Tools
  def ui_note_on_result(%{"command" => cmd}, result) do
    {"shell> #{cmd}", result}
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
        Executes shell commands and returns the output.
        The user must approve execution of this command before it is run.
        The user may optionally approve simple commands for the entire session.

        It is essential to remember that you cannot launch interactive commands!
        Commands that require user input or interaction will fail after a timeout, resulting in a poor experience for the user.

        Supports both simple commands and complex shell syntax:
        - Simple commands: "ls -la", "git log --oneline" (can be pre-approved)
        - Complex commands: "ls | grep foo", "find . -name '*.ex' | head -10" (require manual approval)

        The following simple commands are preapproved and will execute without requiring user approval:

        #{allowed}

        Notes:
        - Simple commands (no pipes, redirects, etc.) can be pre-approved for convenience
        - Complex commands with |, ;, &&, ||, >, <, $(), ` always require manual approval for security
        - Commands with complex operators bypass all pre-approval patterns

        Example usage:
        ```json
        {
          "description": "List files in the current directory",
          "command": "ls -la",
          "timeout_ms": 5000
        }
        ```

        ```json
        {
          "description": "Search for pattern and show first 10 results",
          "command": "rg 'pattern' | head -10",
          "timeout_ms": 10000
        }
        ```
        """,
        parameters: %{
          type: "object",
          required: ["description", "command"],
          properties: %{
            description: %{
              type: "string",
              description: """
              Explain to the user what the command does and why it is needed.
              This will be displayed to the user in the approval dialog.
              """
            },
            command: %{
              type: "string",
              description: """
              The complete shell command to execute. Can be simple (e.g., 'ls -la')
              or complex (e.g., 'find . -name "*.ex" | grep -v test').
              Complex commands with pipes, redirects, etc. will require manual approval.
              """
            },
            timeout_ms: %{
              type: "integer",
              description: """
              Optional execution timeout in milliseconds.
              Defaults to #{@default_timeout_ms}.
              Must be > 0 and ≤ #{@max_timeout_ms}.
              """
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(opts) do
    with {:ok, desc} <- AI.Tools.get_arg(opts, "description"),
         {:ok, command} <- AI.Tools.get_arg(opts, "command"),
         timeout_ms <- validate_timeout(opts),
         {:ok, project} <- Store.get_project(),
         {:ok, :approved} <- confirm(desc, command) do
      call_shell_cmd(command, timeout_ms, project.source_root)
    else
      other -> other
    end
  end

  defp call_shell_cmd(command, timeout_ms, root) do
    command =
      if needs_stdin_redirect?(command) do
        "#{command} < /dev/null"
      else
        command
      end

    Task.async(fn ->
      try do
        System.cmd("sh", ["-c", command],
          stderr_to_stdout: true,
          parallelism: true,
          cd: root
        )
      rescue
        e in ErlangError ->
          case e.reason do
            :enoent -> {:error, "Command not found"}
            :eaccess -> {:error, "Permission denied"}
            other -> {:error, "Posix error: #{Atom.to_string(other)}"}
          end
      end
    end)
    |> run_with_timeout(timeout_ms)
    |> case do
      {:ok, exit_code, out} ->
        {:ok,
         """
         shell> #{command}
         ...$?> #{exit_code}
         #{String.trim_trailing(out)}
         """}

      {:error, message} ->
        UI.debug(command, message)
        {:error, message}
    end
  end

  defp run_with_timeout(task, timeout_ms) do
    case Task.yield(task, timeout_ms) || Task.shutdown(task) do
      {:ok, {out, exit_code}} -> {:ok, exit_code, out}
      {:exit, reason} -> {:error, "Command process existed: #{inspect(reason)}"}
      nil -> {:error, "Command timed out after #{timeout_ms} ms"}
    end
  end

  defp needs_stdin_redirect?(command) do
    cond do
      String.contains?(command, "<") -> false
      String.contains?(command, "|") -> false
      true -> true
    end
  end

  defp validate_timeout(opts) do
    val = Map.get(opts, :timeout_ms, @default_timeout_ms)

    cond do
      !is_integer(val) -> @default_timeout_ms
      val <= 0 -> @default_timeout_ms
      val > @max_timeout_ms -> @max_timeout_ms
      true -> val
    end
  end

  defp confirm(desc, command) do
    Services.Approvals.confirm({command, desc}, Services.Approvals.Shell)
  end
end
