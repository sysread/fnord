defmodule AI.Tools.Shell do
  @moduledoc """
  A tool for executing shell commands.

  Allows for the user to approve a command before it is executed, and provides
  a mechanism to approve all future executions of the same command and
  subcommands, regardless of arguments.
  """

  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: false

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def read_args(args) do
    with {:ok, desc} <- AI.Tools.get_arg(args, "description"),
         {:ok, cmd} <- AI.Tools.get_arg(args, "cmd") do
      cmd = String.trim(cmd)

      cond do
        desc == "" ->
          {:error, :missing_argument, "description"}

        cmd == "" ->
          {:error, :missing_argument, "cmd"}

        AI.Tools.Shell.Util.contains_disallowed_syntax?(cmd) ->
          {:error,
           "Only simple, direct commands are permitted: no pipes, logical operators, redirection, subshells, or command chaining."}

        true ->
          {:ok, %{"description" => desc, "cmd" => cmd}}
      end
    end
  end

  @impl AI.Tools
  def ui_note_on_request(%{"cmd" => cmd}), do: {"Shell", cmd}

  @impl AI.Tools
  def ui_note_on_result(%{"cmd" => cmd}, result) do
    lines = String.split(result, ~r/\r\n|\n/)

    {result_str, additional} =
      if length(lines) > 10 do
        {first_lines, _rest} = Enum.split(lines, 10)
        remaining = length(lines) - 10

        {
          Enum.join(first_lines, "\n"),
          UI.italicize("...plus #{remaining} additional lines")
        }
      else
        {Enum.join(lines, "\n"), ""}
      end

    {"Shell",
     """
     $ #{cmd}
     #{result_str}
     #{additional}
     """}
  end

  @impl AI.Tools
  def spec do
    %{
      type: "function",
      function: %{
        name: "shell_tool",
        description: """
        Executes shell commands and returns the output. The user must approve
        execution of this command before it is run. The user may optionally
        approve the command for the entire session.

        The following commands are always allowed without approval:
        - `ls`
        - `pwd`
        - `find`
        - `cat`
        - `rg`
        - `ag`
        - `grep` (although take care, since it varies between bsd/macOS and GNU/Linux)
        """,
        parameters: %{
          type: "object",
          required: ["description", "cmd"],
          properties: %{
            description: %{
              type: "string",
              description: """
              Explain to the user what the command does and why it is needed.
              This will be displayed to the user in the approval dialog."
              """
            },
            cmd: %{
              type: "string",
              description: "The complete command to execute."
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(args) do
    with {:ok, desc} <- AI.Tools.get_arg(args, "description"),
         {:ok, cmd} <- AI.Tools.get_arg(args, "cmd"),
         false <- AI.Tools.Shell.Util.contains_disallowed_syntax?(cmd),
         {:ok, %{"cmd" => cmd, "args" => args, "approval_bits" => bits}} <- validate(cmd),
         {:ok, :approved} <- confirm(desc, bits, cmd, args) do
      call_shell_cmd(cmd, args)
    end
  end

  defp call_shell_cmd(cmd, args) do
    System.cmd(cmd, args, stderr_to_stdout: true, parallelism: true)
    |> case do
      {output, 0} -> {:ok, String.trim_trailing(output)}
      {output, _} -> {:error, String.trim_trailing(output)}
    end
  end

  defp validate(cmd) do
    AI.Agent.ShellCmdParser.get_response(%{shell_cmd: cmd})
  end

  defp confirm(desc, _, "sh", args) do
    full_cmd =
      ["sh" | args]
      |> Enum.join(" ")

    options = [
      "You son of a bitch, I'm in",
      "Deny",
      "Deny (with feedback)"
    ]

    """
    The AI agent would like to execute a shell command.

    # Command
    ```sh
    #{full_cmd}
    ```

    # Description and Purpose
    > #{desc}

    # Approval
    _Complex commands involving pipes, redirection, command substitution, and
    other shell features cannot be approved for the entire session. You must
    approve each command individually._
    """
    |> UI.choose(options)
    |> case do
      "Deny (with feedback)" ->
        feedback = UI.prompt("Opine away:")

        {:error,
         """
         The user declined to approve the command. They responded with:
         #{feedback}
         """}

      "Deny" ->
        {:error, "The user declined to approve the command."}

      "You son of a bitch, I'm in" ->
        {:ok, :approved}
    end
  end

  defp confirm(desc, approval_bits, cmd, args) do
    full_cmd =
      [cmd | args]
      |> Enum.join(" ")

    approval_str =
      ["You son of a... for the whole session:" | approval_bits]
      |> Enum.join(" ")

    key =
      ["shell_cmd" | approval_bits]
      |> Enum.join("#")

    options = [
      "You son of a bitch, I'm in",
      approval_str,
      "Deny",
      "Deny (with feedback)"
    ]

    key
    |> Once.get()
    |> case do
      {:ok, :approved} ->
        {:ok, :approved}

      _ ->
        """
        The AI agent would like to execute a shell command.

        # Command
        ```sh
        #{full_cmd}
        ```

        # Description and Purpose
        > #{desc}

        # Approval
        You can approve this call only, or you can approve all future calls for
        this command and its subcommands in this session.
        """
        |> UI.choose(options)
        |> case do
          "Deny (with feedback)" ->
            feedback = UI.prompt("Opine away:")

            {:error,
             """
             The user declined to approve the command. They responded with:
             #{feedback}
             """}

          "Deny" ->
            {:error, "The user declined to approve the command."}

          "You son of a bitch, I'm in" ->
            {:ok, :approved}

          ^approval_str ->
            Once.set(key, :approved)
            {:ok, :approved}
        end
    end
  end
end
