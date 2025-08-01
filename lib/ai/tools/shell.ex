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

        contains_disallowed_syntax?(cmd) ->
          {:error, "Only simple, direct commands are permitted: no pipes, logical operators, redirection, subshells, or command chaining."}

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
         false <- contains_disallowed_syntax?(cmd),
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
      "Approve",
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

      "Approve" ->
        {:ok, :approved}
    end
  end

  defp confirm(desc, approval_bits, cmd, args) do
    full_cmd =
      [cmd | args]
      |> Enum.join(" ")

    approval_str =
      ["Approve all for session:" | approval_bits]
      |> Enum.join(" ")

    key =
      ["shell_cmd" | approval_bits]
      |> Enum.join("#")

    options = [
      "Approve",
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

          "Approve" ->
            {:ok, :approved}

          ^approval_str ->
            Once.set(key, :approved)
            {:ok, :approved}
        end
    end
  end

  defp contains_disallowed_syntax?(cmd) when is_binary(cmd) do
    # Use a simpler approach that focuses on catching dangerous unquoted patterns
    # while being permissive for complex quoting scenarios
    try do
      check_dangerous_patterns(cmd)
    rescue
      _ -> true
    catch
      :disallowed -> true
      _ -> true
    else
      false -> false
      true -> true
    end
  end

  defp check_dangerous_patterns(cmd) do
    # Check for command substitution in double quotes first
    has_cmd_substitution_in_double_quotes?(cmd) or
    # Then check unquoted dangerous patterns
    (unquoted_parts = extract_unquoted_parts(cmd, [], :unquoted, "")
     Enum.any?(unquoted_parts, fn part ->
       contains_dangerous_unquoted_pattern?(part)
     end))
  end

  defp has_cmd_substitution_in_double_quotes?(cmd) do
    check_double_quoted_cmd_subst(cmd, :unquoted)
  end

  defp check_double_quoted_cmd_subst("", _state), do: false

  defp check_double_quoted_cmd_subst(<<char::utf8, rest::binary>>, state) do
    case {state, char} do
      {:unquoted, ?'} -> check_double_quoted_cmd_subst(rest, :single_quoted)
      {:unquoted, ?"} -> check_double_quoted_cmd_subst(rest, :double_quoted)
      {:single_quoted, ?'} -> check_double_quoted_cmd_subst(rest, :unquoted)
      {:double_quoted, ?"} -> check_double_quoted_cmd_subst(rest, :unquoted)
      
      {:double_quoted, ?\\} ->
        # Skip escaped character
        case rest do
          <<_next::utf8, remaining::binary>> ->
            check_double_quoted_cmd_subst(remaining, :double_quoted)
          "" ->
            false
        end
        
      {:double_quoted, ?$} ->
        case rest do
          <<"(", _::binary>> -> true  # Found command substitution
          _ -> check_double_quoted_cmd_subst(rest, :double_quoted)
        end
        
      {:double_quoted, ?`} ->
        # Check for backtick command substitution
        case find_closing_backtick_simple(rest) do
          true -> true  # Found backtick command substitution
          false -> check_double_quoted_cmd_subst(rest, :double_quoted)
        end
        
      {_, _} ->
        check_double_quoted_cmd_subst(rest, state)
    end
  end

  defp find_closing_backtick_simple(str) do
    String.contains?(str, "`")
  end

  defp extract_unquoted_parts("", acc, _state, current) do
    if current != "", do: [current | acc], else: acc
  end

  defp extract_unquoted_parts(<<char::utf8, rest::binary>>, acc, state, current) do
    case {state, char} do
      {:unquoted, ?'} ->
        new_acc = if current != "", do: [current | acc], else: acc
        extract_unquoted_parts(rest, new_acc, :single_quoted, "")
        
      {:unquoted, ?"} ->
        new_acc = if current != "", do: [current | acc], else: acc
        extract_unquoted_parts(rest, new_acc, :double_quoted, "")
        
      {:single_quoted, ?'} ->
        extract_unquoted_parts(rest, acc, :unquoted, "")
        
      {:double_quoted, ?"} ->
        extract_unquoted_parts(rest, acc, :unquoted, "")
        
      {:double_quoted, ?\\} ->
        # Skip escaped char in double quotes
        case rest do
          <<_next::utf8, remaining::binary>> ->
            extract_unquoted_parts(remaining, acc, :double_quoted, current)
          "" ->
            extract_unquoted_parts("", acc, :double_quoted, current)
        end
        
      {:unquoted, _} ->
        extract_unquoted_parts(rest, acc, state, current <> <<char>>)
        
      {_, _} ->
        # In quoted context, ignore the character
        extract_unquoted_parts(rest, acc, state, current)
    end
  end

  defp contains_dangerous_unquoted_pattern?(part) do
    # Check for dangerous shell patterns in unquoted text using regex
    Regex.match?(~r/\||&&|\|\||;|>|<|`|\$\(|(?<!\&)\&(?!\&)|<\(|>\(/, part)
  end
end
