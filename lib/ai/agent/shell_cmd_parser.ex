defmodule AI.Agent.ShellCmdParser do
  @behaviour AI.Agent

  @max_attempts 3

  @model AI.Model.balanced()

  @prompt """
  You are an expert shell parser.
  Your job is to analyze a given shell command string, extract its structural components, and output a strict JSON object as specified below.

  Instructions:

  - Read the command as a user would type it in a shell, e.g., `git -C path rev-parse --show-toplevel`.
  - Parse out the **base command** (the executable), and group any "subcommand" or "verb" that acts as a command selector.
  - For commands like `git rev-parse`, the subcommand is `rev-parse`.
  - The "cmd" field must be the main executable (e.g., "git").
  - The "args" field must be an array of all following tokens, preserving their order.
  - The "approval_bits" array must contain the executable and any subcommands that define a *unique operation*.
  - For example, for `git -C path rev-parse --show-toplevel`, the approval_bits are ["git", "rev-parse"] (ignore flags and options).
  - For `find . -type f`, approval_bits is just ["find"].
  - For `docker run -it ubuntu`, approval_bits is ["docker", "run"].
  - If the input cannot be confidently parsed, provide an error message explaining why.

  Special rules

  - Do **not** attempt to guess meanings—split strictly on whitespace, respecting quoted arguments.
  - Treat the first token as "cmd", everything else as "args".
  - "approval_bits" should only include the executable and literal subcommands (verbs), not options or arguments.  
  - If the command is ambiguous or doesn't fit the above (e.g., missing executable), respond with an error.
  - If the command is obviously malformed or incomplete (e.g., missing or duplicated command or arguments, or contains only flags/options without a command), respond with an error.
  - If the command includes any of the following constructs, the "cmd" is "sh", and "args" is ["-c", "<entire_command>"]:
    - Execution through ANY shell (e.g., `sh -c '...'`, `bash -c '...'`, `zsh -c '...'`)
    - redirection (`>`, `>>`, `<`, `2>`)
    - pipes (`|`)
    - subshells or command substitution (`$()`, `` ` ``)
    - logical operators (`&&`, `||`)
    - semicolons (`;`)
    - backgrounding (`&`)
    - process substitution (`<(...)`, `>(...)`)
  """

  @response_format %{
    type: "json_schema",
    json_schema: %{
      name: "shell_command_parse",
      description: """
      A JSON object containing the parsed components of a shell command,
      or an error message if the command cannot be parsed.
      """,
      schema: %{
        type: "object",
        properties: %{
          cmd: %{
            type: "string",
            minLength: 1,
            description: "The main executable command"
          },
          args: %{
            type: "array",
            items: %{type: "string"},
            description: "Array of all arguments following the command"
          },
          approval_bits: %{
            type: "array",
            items: %{type: "string"},
            minItems: 1,
            description:
              "Array containing the executable and any subcommands that define a unique operation"
          },
          error: %{
            type: "string",
            description: "Error message explaining why the command could not be parsed"
          }
        },
        additionalProperties: false
      }
    }
  }

  @impl AI.Agent
  def get_response(opts) do
    with {:ok, shell_cmd} <- Map.fetch(opts, :shell_cmd) do
      shell_cmd
      |> String.trim()
      |> do_stuff()
    end
  end

  defp do_stuff(shell_cmd, attempt \\ 1)

  defp do_stuff(shell_cmd, attempt) when attempt <= @max_attempts do
    shell_cmd
    |> get_completion()
    |> validate_response()
    |> case do
      {:ok, result} ->
        {:ok, result}

      {:rejected, reason} ->
        {:error, "Command rejected: #{reason}"}

      {:invalid_format, reason} ->
        UI.warn("[shell-cmd-parser]", "Input: #{inspect(shell_cmd)}, Error: #{inspect(reason)}")
        do_stuff(shell_cmd, attempt + 1)
    end
  end

  defp do_stuff(_shell_cmd, _attempt) do
    {:error, "Failed to parse command after #{@max_attempts} attempts."}
  end

  defp get_completion(shell_cmd) do
    AI.Completion.get(
      log_msgs: false,
      log_tool_calls: false,
      model: @model,
      response_format: @response_format,
      messages: [
        AI.Util.system_msg(@prompt),
        AI.Util.user_msg("""
        Please parse the following shell command:
        ```sh
        #{shell_cmd}
        ```
        """)
      ]
    )
    |> case do
      {:ok, %{response: response}} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_response({:error, reason}), do: {:error, reason}

  defp validate_response({:ok, response}) do
    # JSON parsing and structure validation is now guaranteed by response_format
    case Jason.decode!(response) do
      %{"error" => error} ->
        {:rejected, error}

      %{"cmd" => cmd, "args" => args, "approval_bits" => approval_bits} = parsed ->
        # Basic sanity checks (though schema should prevent these)
        cond do
          not is_binary(cmd) or cmd == "" ->
            {:invalid_format, "The 'cmd' field must be a non-empty string."}

          not is_list(args) ->
            {:invalid_format, "The 'args' field must be an array."}

          not is_list(approval_bits) or length(approval_bits) == 0 ->
            {:invalid_format, "The 'approval_bits' field must be a non-empty array."}

          true ->
            {:ok, parsed}
        end

      result ->
        # Handle case where neither proper fields nor error is provided
        if Map.has_key?(result, "cmd") || Map.has_key?(result, "args") ||
             Map.has_key?(result, "approval_bits") do
          {:invalid_format, "Incomplete command parsing result"}
        else
          {:invalid_format, "No valid command parse or error provided"}
        end
    end
  end
end
