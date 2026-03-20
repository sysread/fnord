defmodule Validation.Rules do
  @moduledoc """
  Evaluates and runs project-scoped validation rules after code-modifying tool
  usage.

  This module is the feature-owned context for validation rule matching,
  command execution, and result summarization. It does not implement the
  `AI.Agent` behaviour; instead, higher-level orchestrators call into it at the
  points where validation rules must be selected and executed.

  It determines which validation commands apply to the current set of changed
  files, expands any glob-like command arguments within the project root, and
  then runs matching commands without invoking a shell.
  """

  @type rule :: Settings.Validation.rule()

  @type command_result :: %{
          command: String.t(),
          status: non_neg_integer(),
          output: String.t()
        }

  @type result ::
          {:ok, :no_changes}
          | {:ok, :no_rules, [String.t()], String.t()}
          | {:ok, :no_matches, [String.t()], String.t()}
          | {:ok, [command_result()], String.t()}
          | {:error, command_result(), String.t()}
          | {:error, :discovery_failed}

  @doc """
  Runs validation for the currently selected project against the current
  working tree changes.
  """
  @spec run() :: result()
  def run() do
    with {:ok, project} <- Store.get_project() do
      run(project.name, project.source_root)
    end
  end

  @doc """
  Runs validation for the given project name and root.

  This integration-point function discovers changed files, selects the
  configured commands whose validation rules apply, executes those commands
  directly from the project root, and returns a structured summary of the
  outcome.
  """
  @spec run(String.t(), String.t()) :: result()
  def run(project_name, root) when is_binary(project_name) and is_binary(root) do
    case changed_files(root) do
      {:error, :discovery_failed} ->
        debug("git status failed - cannot determine changed files")
        {:error, :discovery_failed}

      {:ok, []} ->
        debug("Nothing to do")
        {:ok, :no_changes}

      {:ok, changed_files} ->
        fingerprint = fingerprint(changed_files)

        debug("Changed files: #{inspect(changed_files)}")

        rules = Settings.Validation.list(project_name)
        commands = matching_commands(rules, changed_files)

        debug("Rules considered: #{format_rules_for_debug(rules)}")
        debug("Matching commands: #{inspect(commands)}")

        run_matching_commands(project_name, rules, commands, changed_files, fingerprint, root)
    end
  end

  @doc """
  Returns a stable fingerprint for a changed-file set.
  """
  @spec fingerprint([String.t()]) :: String.t()
  def fingerprint(changed_files) when is_list(changed_files) do
    changed_files
    |> Enum.sort()
    |> Enum.join("\n")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Formats a result into a summary suitable for UI output or a system message.
  """
  @spec summarize(result()) :: String.t()
  def summarize({:ok, :no_changes}) do
    "Validation skipped: no changed files detected."
  end

  def summarize({:ok, :no_rules, changed_files, _fingerprint}) do
    "Validation skipped: #{length(changed_files)} changed file(s), but no rules are configured."
  end

  def summarize({:ok, :no_matches, changed_files, _fingerprint}) do
    "Validation skipped: #{length(changed_files)} changed file(s), but no rules matched."
  end

  def summarize({:ok, results, _fingerprint}) do
    [
      "Validation passed: #{length(results)} command(s) succeeded.",
      format_successful_commands(results)
    ]
    |> Enum.join("\n")
  end

  def summarize({:error, :discovery_failed}) do
    "Validation failed: could not determine changed files (git status failed)."
  end

  def summarize({:error, result, _fingerprint}) do
    format_failure_summary(result)
  end

  @spec format_successful_commands([command_result()]) :: String.t()
  defp format_successful_commands(results) do
    results
    |> Enum.map_join("\n", &format_successful_command/1)
  end

  @spec format_successful_command(command_result()) :: String.t()
  defp format_successful_command(%{command: command}) do
    "- `#{command}` ran successfully."
  end

  @spec format_failure_summary(command_result()) :: String.t()
  defp format_failure_summary(%{command: command, status: status, output: output}) do
    [
      "Validation failed:",
      "- `#{command}` exited with status #{status}.",
      "Full output:",
      output
    ]
    |> Enum.join("\n")
  end

  # Feature-scoped debug tracing for validation decisions and command execution.
  @doc """
  Emits feature-scoped validation debug tracing when `FNORD_DEBUG_VALIDATION`
  is truthy.
  """
  @spec debug(String.t()) :: :ok
  def debug(message) do
    debug("Validation", message)
  end

  @doc """
  Emits feature-scoped validation debug tracing when `FNORD_DEBUG_VALIDATION`
  is truthy.
  """
  @spec debug(String.t(), String.t()) :: :ok
  def debug(label, message) do
    if Util.Env.looks_truthy?("FNORD_DEBUG_VALIDATION") do
      UI.debug(label, message)
    end

    :ok
  end

  @spec format_rules_for_debug([rule()]) :: String.t()
  defp format_rules_for_debug(rules) do
    rules
    |> Enum.map(&Map.take(&1, [:command, :path_globs]))
    |> inspect()
  end

  @doc """
  Returns the current changed files for the project root as project-relative
  paths. Returns an error if git status cannot be determined, since silent
  failure in a guardrail feature would mask real problems.
  """
  @spec changed_files(String.t()) :: {:ok, [String.t()]} | {:error, :discovery_failed}
  def changed_files(root) when is_binary(root) do
    case git_status_lines(root) do
      {:ok, lines} ->
        files =
          lines
          |> Enum.reduce([], fn line, acc ->
            case parse_status_line(line) do
              {:ok, rel_path} -> [rel_path | acc]
              :skip -> acc
            end
          end)
          |> Enum.uniq()
          |> Enum.sort()

        {:ok, files}

      {:error, :git_failed} ->
        {:error, :discovery_failed}
    end
  end

  @doc """
  Returns the matching command strings for the given rules and changed files.
  Duplicate commands are collapsed while preserving first-match order.
  """
  @spec matching_commands([rule()], [String.t()]) :: [String.t()]
  def matching_commands(rules, changed_files) do
    rules
    |> Enum.filter(fn rule -> rule_matches?(rule, changed_files) end)
    |> Enum.map(& &1.command)
    |> Enum.uniq()
  end

  @doc """
  Expands a command string into an executable and argv list suitable for direct
  execution with `System.cmd/3`.
  """
  @spec expand_command(String.t(), String.t()) :: {String.t(), [String.t()]}
  def expand_command(command, root) when is_binary(command) and is_binary(root) do
    [executable | argv] = OptionParser.split(command)
    {executable, expand_argv(argv, root)}
  end

  @doc """
  Expands and executes one configured validation command from the project root
  as a direct process invocation.
  """
  @spec execute_validation_command(String.t(), String.t()) ::
          {:ok, command_result()} | {:error, command_result()}
  def execute_validation_command(command, root) when is_binary(command) and is_binary(root) do
    {executable, argv} = expand_command(command, root)

    try do
      UI.report_step("Validation", command)
      {output, status} = System.cmd(executable, argv, cd: root, stderr_to_stdout: true)
      result = %{command: command, status: status, output: output}

      case status do
        0 ->
          UI.end_step("Validation", "#{command}")
          {:ok, result}

        _ ->
          UI.fail_step("Validation", """
          $ #{command}
          #{output}
          """)

          {:error, result}
      end
    rescue
      error ->
        debug("""
        Raised an exception while executing: #{inspect(command)}

        #{Exception.format(:error, error, __STACKTRACE__)}
        """)

        {:error, %{command: command, status: 1, output: Exception.message(error)}}
    end
  end

  @spec run_matching_commands(
          String.t(),
          [rule()],
          [String.t()],
          [String.t()],
          String.t(),
          String.t()
        ) ::
          result()
  defp run_matching_commands(_project_name, rules, [], changed_files, fingerprint, _root) do
    if rules == [] do
      debug("Skipped - no rules configured for project")
      {:ok, :no_rules, changed_files, fingerprint}
    else
      debug("Skipped - changed files did not match any rules")
      {:ok, :no_matches, changed_files, fingerprint}
    end
  end

  defp run_matching_commands(_project_name, _rules, commands, _changed_files, fingerprint, root) do
    commands
    |> Enum.reduce_while([], fn command, acc ->
      case execute_validation_command(command, root) do
        {:ok, result} -> {:cont, [result | acc]}
        {:error, result} -> {:halt, {:error, result, fingerprint, Enum.reverse(acc)}}
      end
    end)
    |> case do
      {:error, result, failing_fingerprint, _prior_results} ->
        {:error, result, failing_fingerprint}

      results ->
        {:ok, Enum.reverse(results), fingerprint}
    end
  end

  @spec rule_matches?(rule(), [String.t()]) :: boolean
  defp rule_matches?(rule, changed_files) do
    Enum.any?(rule.path_globs, fn path_glob ->
      path_glob_matches_changed_files?(path_glob, changed_files)
    end)
  end

  # Returns true when the path glob applies to the selected project.
  #
  # The explicit project-root sentinel glob "." bypasses per-file glob matching
  # once rule evaluation is happening, but it does not bypass the outer
  # `changed_files == []` short-circuit in `run/2`.
  @spec path_glob_matches_changed_files?(String.t(), [String.t()]) :: boolean
  defp path_glob_matches_changed_files?(".", _changed_files), do: true

  defp path_glob_matches_changed_files?(path_glob, changed_files) do
    glob_matches_any_changed_file?(path_glob, changed_files)
  end

  @doc """
  Returns true when the glob pattern matches at least one changed file.
  """
  @spec glob_matches_any_changed_file?(String.t(), [String.t()]) :: boolean
  def glob_matches_any_changed_file?(path_glob, changed_files) do
    path_glob
    |> expand_braces()
    |> Enum.any?(fn expanded_glob ->
      regex = glob_to_regex(expanded_glob)
      Enum.any?(changed_files, &Regex.match?(regex, &1))
    end)
  end

  @doc """
  Expands argv tokens that contain glob syntax into matching project-relative
  file paths.
  """
  @spec expand_argv([String.t()], String.t()) :: [String.t()]
  def expand_argv(argv, root) do
    argv
    |> Enum.flat_map(&expand_token(&1, root))
  end

  @doc """
  Expands a single token. Unmatched patterns are preserved literally so the
  called program can emit its own diagnostic.
  """
  @spec expand_token(String.t(), String.t()) :: [String.t()]
  def expand_token(token, root) do
    if glob_token?(token) do
      token
      |> expand_braces()
      |> Enum.flat_map(&resolve_expanded_token(&1, root))
      |> Enum.uniq()
      |> case do
        [] -> [token]
        matches -> matches
      end
    else
      [token]
    end
  end

  @spec resolve_expanded_token(String.t(), String.t()) :: [String.t()]
  defp resolve_expanded_token(pattern, root) do
    if wildcard_pattern?(pattern) do
      wildcard_matches(pattern, root)
    else
      path = Path.join(root, pattern)

      cond do
        not Util.path_within_root?(path, root) ->
          []

        File.exists?(path) and File.dir?(path) ->
          path
          |> Path.wildcard(match_dot: true)
          |> Enum.filter(&Util.path_within_root?(&1, root))
          |> Enum.map(&Path.relative_to(&1, root))
          |> case do
            [] -> [pattern]
            matches -> matches
          end

        File.exists?(path) ->
          [Path.relative_to(path, root)]

        true ->
          []
      end
    end
  end

  @doc """
  Expands a brace expression such as `{lib,test}/**/*.ex` into a list of plain
  glob patterns. Handles nested braces like `{lib/{src,test},docs}/**/*.ex` by
  finding the innermost brace pair first and expanding outward.
  """
  @spec expand_braces(String.t()) :: [String.t()]
  def expand_braces(pattern) when is_binary(pattern) do
    case find_innermost_braces(pattern) do
      nil ->
        [pattern]

      {prefix, inner, suffix} ->
        inner
        |> String.split(",")
        |> Enum.flat_map(fn part ->
          expand_braces(prefix <> part <> suffix)
        end)
    end
  end

  # Finds the innermost `{...}` group by locating the last `{` before the first
  # `}`. This ensures nested braces like `{a/{b,c},d}` expand from the inside
  # out.
  @spec find_innermost_braces(String.t()) :: {String.t(), String.t(), String.t()} | nil
  defp find_innermost_braces(pattern) do
    case :binary.match(pattern, "}") do
      :nomatch ->
        nil

      {close_pos, _} ->
        prefix = binary_part(pattern, 0, close_pos)

        case last_index_of(prefix, "{") do
          nil ->
            nil

          open_pos ->
            {
              binary_part(pattern, 0, open_pos),
              binary_part(pattern, open_pos + 1, close_pos - open_pos - 1),
              binary_part(pattern, close_pos + 1, byte_size(pattern) - close_pos - 1)
            }
        end
    end
  end

  @spec last_index_of(String.t(), String.t()) :: non_neg_integer() | nil
  defp last_index_of(string, char) do
    string
    |> :binary.matches(char)
    |> case do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end

  @doc """
  Converts a bash-style path glob into a regular expression that matches a
  project-relative path.
  """
  @spec glob_to_regex(String.t()) :: Regex.t()
  def glob_to_regex(glob) when is_binary(glob) do
    glob
    |> Regex.escape()
    |> String.replace("\\*\\*/", "(?:.+/)?")
    |> String.replace("\\*\\*", ".*")
    |> String.replace("\\*", "[^/]*")
    |> String.replace("\\?", "[^/]")
    |> then(&"^#{&1}$")
    |> Regex.compile!()
  end

  @spec wildcard_pattern?(String.t()) :: boolean
  defp wildcard_pattern?(pattern) do
    String.contains?(pattern, ["*", "?", "["])
  end

  @spec wildcard_matches(String.t(), String.t()) :: [String.t()]
  defp wildcard_matches(pattern, root) do
    root
    |> Path.join(pattern)
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&Util.path_within_root?(&1, root))
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.sort()
  rescue
    _ -> []
  end

  @spec glob_token?(String.t()) :: boolean
  defp glob_token?(token) do
    String.contains?(token, ["*", "?", "[", "{"])
  end

  @spec git_status_lines(String.t()) :: {:ok, [String.t()]} | {:error, :git_failed}
  defp git_status_lines(root) do
    case System.cmd("git", ["status", "--short", "--untracked-files=all"], cd: root) do
      {output, 0} -> {:ok, String.split(output, "\n", trim: true)}
      {_output, _status} -> {:error, :git_failed}
    end
  end

  @spec parse_status_line(String.t()) :: {:ok, String.t()} | :skip
  defp parse_status_line(<<status::binary-size(2), " ", path::binary>>) do
    if String.contains?(status, "D") do
      :skip
    else
      {:ok, normalize_status_path(path)}
    end
  end

  defp parse_status_line(_line), do: :skip

  @spec normalize_status_path(String.t()) :: String.t()
  defp normalize_status_path(path) do
    path
    |> String.trim()
    |> String.split(" -> ")
    |> List.last()
  end
end
