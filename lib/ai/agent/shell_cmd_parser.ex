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
  - If the input cannot be confidently parsed, output only: `{"error": "<reason>"}`

  Output format

  ```json
  {
  "cmd": "<base_command>",
  "args": ["<arg1>", "<arg2>", ...],
  "approval_bits": ["<base_command>", "<subcommand>", ...]
  }
  ```

  Examples

  - Input: `git -C /repo diff --stat`
  Output:
  ```json
  {
    "cmd": "git",
    "args": ["-C", "/repo", "diff", "--stat"],
    "approval_bits": ["git", "diff"]
  }
  ```

  - Input: `find . -type f`
  Output:
  ```json
  {
    "cmd": "find",
    "args": [".", "-type", "f"],
    "approval_bits": ["find"]
  }
  ```

  - Input: `docker run -it alpine`
  Output:
  ```json
  {
    "cmd": "docker",
    "args": ["run", "-it", "alpine"],
    "approval_bits": ["docker", "run"]
  }
  ```

  - Input: `ls -l`
  Output:
  ```json
  {
    "cmd": "ls",
    "args": ["-l"],
    "approval_bits": ["ls"]
  }
  ```

  Do NOT include explanations, summary, or markdown fences in your response.
  Respond in pure, strict JSON format as specified above.

  Special rules

  - Do **not** attempt to guess meanings—split strictly on whitespace, respecting quoted arguments.
  - Treat the first token as "cmd", everything else as "args".
  - "approval_bits" should only include the executable and literal subcommands (verbs), not options or arguments.  
  - If the command is ambiguous or doesn't fit the above (e.g., missing executable), output only the error object.
  - If the command is obviously malformed or incomplete (e.g., missing or duplicated command or arguments, or contains only flags/options without a command), respond with an error.
  - If the command includes any of the following constructs, the "cmd" is "sh", and "args" is ["-c", "<entire_command>"]:
    - redirection (`>`, `>>`, `<`, `2>`)
    - pipes (`|`)
    - subshells or command substitution (`$()`, `` ` ``)
    - logical operators (`&&`, `||`)
    - semicolons (`;`)
    - backgrounding (`&`)
    - process substitution (`<(...)`, `>(...)`)
  """

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
    case Jason.decode(response) do
      {:error, reason} ->
        {:invalid_format, "Invalid JSON response: #{inspect(reason)}"}

      {:ok, %{"error" => error}} ->
        {:rejected, error}

      {:ok, %{"cmd" => cmd, "args" => args, "approval_bits" => approval_bits} = parsed} ->
        cond do
          not is_binary(cmd) ->
            {:invalid_format, "The 'cmd' field must be a string."}

          not is_list(args) ->
            {:invalid_format, "The 'args' field must be an array."}

          not is_list(approval_bits) ->
            {:invalid_format, "The 'approval_bits' field must be an array."}

          true ->
            {:ok, parsed}
        end
    end
  end
end
