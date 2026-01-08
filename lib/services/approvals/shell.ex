defmodule Services.Approvals.Shell do
  # ----------------------------------------------------------------------------
  # Globals
  # ----------------------------------------------------------------------------
  @type state :: Services.Approvals.Workflow.state()
  @type decision :: Services.Approvals.Workflow.decision()
  @type args :: {String.t(), list(map), String.t()}

  @approve "Approve"
  @persistent "Approve persistently"
  @deny "Deny"
  @deny_feedback "Deny with feedback"

  @session "Approve for this session"
  @project "Approve for the project"
  @global "Approve globally"

  @no_feedback "The user denied the request."

  @no_tty """
  The application is not running in an interactive terminal.
  The user cannot respond to prompts, so they were unable to approve or deny the request.
  """

  # ----------------------------------------------------------------------------
  # Behaviour implementation
  # ----------------------------------------------------------------------------
  @behaviour Services.Approvals.Workflow

  @impl Services.Approvals.Workflow
  @spec confirm(state, args) :: decision
  def confirm(state, {op, commands, purpose}) when is_list(commands) do
    with :ok <- validate_commands(commands) do
      # Build list of {prefix, full_command} pairs
      stages =
        Enum.map(commands, fn cmd ->
          {
            extract_prefix(cmd),
            format_stage_for_match(cmd)
          }
        end)

      case reject_shell_invocations(state, commands) do
        {:error, reason} ->
          {:denied, reason, state}

        :ok ->
          if Enum.all?(stages, &approved?(state, &1)) do
            {:approved, state}
          else
            if !UI.is_tty?() do
              UI.error("Shell", @no_tty)
              {:denied, @no_tty, state}
            else
              UI.interact(fn ->
                render_pipeline(state, op, commands, purpose)
                prompt(state, stages)
              end)
            end
          end
      end
    else
      {:error, reason} -> {:denied, reason, state}
    end
  end

  # Input validation
  # ----------------------------------------------------------------------------
  defp validate_commands([]), do: :ok

  defp validate_commands([cmd | rest]) do
    with :ok <- validate_command(cmd),
         :ok <- validate_commands(rest) do
      :ok
    end
  end

  defp validate_command(%{"command" => cmd, "args" => args}) do
    cond do
      !is_binary(cmd) -> {:error, "command must be a string"}
      !is_list(args) -> {:error, "args must be a list"}
      !Enum.all?(args, &is_binary/1) -> {:error, "all args must be strings"}
      true -> :ok
    end
  end

  defp validate_command(_), do: {:error, "expected object with keys 'command' and 'args'"}

  # ----------------------------------------------------------------------------
  # Approval checks
  # ----------------------------------------------------------------------------
  # Pre-approved regex for read-only sed commands commonly used by LLMs
  # Supports: -n (quiet), -E (extended regex), basic s/// substitutions, p (print), d (delete without -i)
  # Blocks: -i (in-place), -f (script files), -e (expressions), s///e (execute), w/W/r file operations
  # no in-place editing
  # no script files
  # no -e expressions (conservative)
  # no s///e or s|||e execute in substitution
  # no w/W/r commands with filenames
  # no addressed w/W/r commands
  # no range w/W/r commands
  @sed_readonly_pattern "^sed" <>
                          "(?!.*\\s-i\\b)" <>
                          "(?!.*\\s-f\\b)" <>
                          "(?!.*\\s-e\\b)" <>
                          "(?!.*s[|/].*[|/].*[|/][gp0-9]*e)" <>
                          "(?!.*\\b[wWr]\\s+\\S)" <>
                          "(?!.*\\d+[wWr]\\b)" <>
                          "(?!.*,[wWr]\\b)" <>
                          ".+$"

  @full_cmd [
    "^find(?!.*-exec)",
    @sed_readonly_pattern
  ]

  @ro_cmd [
    "ag",
    "cat",
    "col",
    "cut",
    "diff",
    "echo",
    "fgrep",
    "grep",
    "head",
    "jq",
    "ls",
    "nl",
    "pwd",
    "rg",
    "shellcheck",
    "sort",
    "tac",
    "tail",
    "tr",
    "tree",
    "uniq",
    "wc",

    # git subcommands
    "git blame",
    "git branch",
    "git describe",
    "git diff",
    "git grep",
    "git log",
    "git ls-files",
    "git ls-tree",
    "git merge-base",
    "git rev-list",
    "git rev-parse",
    "git show",
    "git status"
  ]

  @rw_cmd [
    "mkdir",
    "touch",
    "cp",
    "mv",
    "rm",
    "sed",
    "awk",
    "patch",
    "truncate"
  ]

  def preapproved_cmds do
    if edit?() and auto?() do
      @ro_cmd ++ @rw_cmd
    else
      @ro_cmd
    end
  end

  # Returns true if either the prefix path or the full command string is
  # approved or a stored full-command approval matches this stage.
  defp approved?(state, {prefix, full}) do
    prefix_approved?(state, prefix) or
      full_literal_prefix_approved?(state, full) or
      full_cmd_preapproved?(state, full)
  end

  defp session_approvals(%{session: session}, kind) do
    session
    |> Enum.reduce([], fn
      {^kind, prefix}, acc -> [prefix | acc]
      _, acc -> acc
    end)
  end

  def prefix_approved?(state, prefix) do
    cond do
      prefix in preapproved_cmds() -> true
      prefix in session_approvals(state, :prefix) -> true
      Settings.Approvals.prefix_approved?(Settings.new(), "shell", prefix) -> true
      true -> false
    end
  end

  def full_cmd_preapproved?(state, full) do
    Settings.Approvals.approved?(Settings.new(), "shell_full", full) or
      @full_cmd
      |> Enum.concat(session_approvals(state, :full))
      |> Enum.map(fn re -> Regex.compile!(re, "u") end)
      |> Enum.any?(&Regex.match?(&1, full))
  end

  defp full_literal_prefix_approved?(state, full) do
    settings = Settings.new()

    stored =
      Settings.Approvals.get_approvals(settings, :global, "shell") ++
        Settings.Approvals.get_approvals(settings, :project, "shell")

    session_prefixes =
      state
      |> Map.get(:session, [])
      |> Enum.flat_map(fn
        {:prefix, p} when is_binary(p) -> [p]
        _ -> []
      end)

    (stored ++ session_prefixes)
    |> Enum.any?(fn p -> is_binary(p) and String.starts_with?(full, p) end)
  end

  # ----------------------------------------------------------------------------
  # Display
  # ----------------------------------------------------------------------------
  defp render_pipeline(state, op, commands, purpose) do
    stages =
      commands
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {cmd, i} ->
        tags =
          if approved?(state, {extract_prefix(cmd), format_stage_for_match(cmd)}) do
            [:green, :bright]
          else
            [:red, :bright]
          end

        formatted = format_stage(cmd)
        item = "#{i}. #{formatted}"

        [Owl.Data.tag(item, tags), "\n\n"]
      end)

    op_msg =
      case op do
        "|" -> "Pipeline of Commands"
        "&&" -> "Chained Commands"
      end

    [
      Owl.Data.tag("# Approval Scope ", [:red_background, :black, :bright]),
      "\n\n#{op_msg}:\n\n"
    ]
    |> Enum.concat(stages)
    |> Enum.concat([
      Owl.Data.tag("# Purpose ", [:red_background, :black, :bright]),
      "\n\n",
      purpose
    ])
    |> UI.box(
      title: " Shell ",
      min_width: 80,
      padding: 1,
      horizontal_align: :left,
      border_tag: [:red, :bright]
    )
  end

  defp format_stage(%{"command" => cmd, "args" => args}) do
    Enum.join([cmd | args], " ")
  end

  # Build the string used for shell_full matching: use basename(command) + args
  defp format_stage_for_match(%{"command" => cmd, "args" => args}) do
    base =
      if String.starts_with?(cmd, "./") do
        cmd
      else
        Path.basename(cmd)
      end

    Enum.join([base | args], " ")
  end

  # ----------------------------------------------------------------------------
  # Prompt + persistence
  # ----------------------------------------------------------------------------
  defp prompt(state, stages) do
    opts = [@approve, @persistent, @deny, @deny_feedback]

    Settings.get_auto_policy()
    |> case do
      {:approve, ms} -> UI.choose("Approve this request?", opts, ms, @approve)
      {:deny, ms} -> UI.choose("Approve this request?", opts, ms, @deny)
      _ -> UI.choose("Approve this request?", opts)
    end
    |> case do
      @approve ->
        {:approved, state}

      @deny ->
        {:denied, build_auto_deny_message(), state}

      @deny_feedback ->
        {:denied, get_feedback(), state}

      @persistent ->
        customize(state, stages)
    end
  end

  defp unapproved_prefixes(state, stages) do
    stages
    |> Enum.uniq()
    |> Enum.reject(fn {prefix, full} -> approved?(state, {prefix, full}) end)
    |> Enum.map(fn {prefix, _full} -> prefix end)
    |> Enum.uniq()
  end

  @spec customize(state, list({String.t(), String.t()})) :: {:approved, state}
  def customize(state, stages) do
    unapproved_prefixes(state, stages)
    |> Enum.reduce({:approved, state}, fn prefix, {:approved, acc_state} ->
      choose_scope(acc_state, prefix)
    end)
  end

  defp choose_scope(state, prefix) do
    {kind, pattern} = custom_pattern(state, prefix)

    scope =
      UI.choose(
        """
        Choose approval scope for:
            #{pattern}
        """,
        [@session, @project, @global]
      )

    case kind do
      :prefix -> approve_scope(scope, state, pattern)
      :full -> approve_regex_scope(scope, state, pattern, prefix)
    end
  end

  defp custom_pattern(state, prefix) do
    UI.prompt(
      """
      You may optionally select your own approval prefix, making it broader or more specific.

      Wrap your input in slashes (/) to treat it as a regular expression.
      Regular expressions are matched against the entire command string, including arguments.
      There is NO implicit anchoring, so include ^ and $ as needed.

      Options:
      1. Customize the prefix (e.g. `docker image` to `docker image ls` or `docker` to change the specificity)
      2. Enter a regular expression (e.g. `/^find(?!.*-exec).+$/` to allow find without -exec)
      3. *Leave blank* to approve the default prefix as shown.

      CURRENT PREFIX: #{prefix}
      """,
      optional: true
    )
    |> case do
      {:error, :no_tty} ->
        {:prefix, prefix}

      nil ->
        {:prefix, prefix}

      "" ->
        {:prefix, prefix}

      str ->
        str = String.trim(str)

        if String.starts_with?(str, "/") and String.ends_with?(str, "/") do
          re = String.slice(str, 1..-2//1)

          if re == "" do
            UI.error("Empty regex is not allowed")
            custom_pattern(state, prefix)
          else
            case Regex.compile(re, "u") do
              {:ok, _} ->
                {:full, re}

              {:error, {msg, _pos}} ->
                UI.error("Invalid regex: #{to_string(msg)}")
                custom_pattern(state, prefix)
            end
          end
        else
          {:prefix, str}
        end
    end
  end

  defp approve_scope(@session, %{session: session} = state, prefix) do
    prefixes = session |> Enum.concat([{:prefix, prefix}]) |> Enum.uniq()
    {:approved, %{state | session: prefixes}}
  end

  defp approve_scope(@project, state, prefix) do
    Settings.new() |> Settings.Approvals.approve(:project, "shell", prefix)
    {:approved, state}
  end

  defp approve_scope(@global, state, prefix) do
    Settings.new() |> Settings.Approvals.approve(:global, "shell", prefix)
    {:approved, state}
  end

  defp approve_regex_scope(@session, %{session: session} = state, inner, _prefix) do
    prefixes = session |> Enum.concat([{:full, inner}]) |> Enum.uniq()
    {:approved, %{state | session: prefixes}}
  end

  defp approve_regex_scope(@project, state, inner, _prefix) do
    Settings.new() |> Settings.Approvals.approve(:project, "shell_full", inner)
    {:approved, state}
  end

  defp approve_regex_scope(@global, state, inner, _prefix) do
    Settings.new() |> Settings.Approvals.approve(:global, "shell_full", inner)
    {:approved, state}
  end

  # ----------------------------------------------------------------------------
  # Utilities
  # ----------------------------------------------------------------------------

  @doc """
  Delegate to the pure prefix extraction logic.
  """
  def extract_prefix(%{"command" => cmd, "args" => args}) do
    # If the command appears to be a path (contains a slash), preserve the literal
    # command (including leading ./) so approvals can distinguish `./make` vs `make`.
    if String.starts_with?(cmd, "./") do
      cmd
    else
      base_cmd = Path.basename(cmd)
      Services.Approvals.Shell.Prefix.extract(base_cmd, args)
    end
  end

  # Helper to detect shell invocations
  defp shell_invocation?(%{"command" => path, "args" => args}) do
    base = Path.basename(path)
    shells = ["sh", "bash", "zsh", "ksh", "dash", "fish"]

    cond do
      # direct shell invocation: bash/sh/zsh/ksh/dash/fish -c/ -lc
      base in shells and Enum.any?(args, &(&1 == "-c" or &1 == "-lc")) ->
        true

      # shell script invocation without -c/-lc: exec script file
      base in shells and Enum.find(args, fn arg -> not String.starts_with?(arg, "-") end) != nil ->
        true

      # env-based shell invocation: env [VAR=val]* [flags]* bash -c '...' or script
      base == "env" ->
        has_shell = Enum.any?(args, &(&1 in shells))
        has_flag = Enum.any?(args, &(&1 == "-c" or &1 == "-lc"))

        has_non_flag_after =
          case Enum.find_index(args, &(&1 in shells)) do
            nil ->
              false

            idx ->
              args
              |> Enum.drop(idx + 1)
              |> Enum.any?(fn arg -> not String.starts_with?(arg, "-") end)
          end

        has_shell and (has_flag or has_non_flag_after)

      true ->
        false
    end
  end

  # Reject any shell invocations in the commands list
  @spec reject_shell_invocations(state, [map]) :: :ok | {:error, String.t()}
  defp reject_shell_invocations(_state, commands) do
    case Enum.find(commands, &shell_invocation?/1) do
      invoc when not is_nil(invoc) ->
        {:error, "shell invocation not allowed: #{format_stage(invoc)}"}

      nil ->
        :ok
    end
  end

  # Prompt user for feedback when denying with feedback
  defp get_feedback do
    "Feedback:"
    |> UI.prompt()
    |> then(&"The user denied the request with the following feedback: #{&1}")
  end

  defp build_auto_deny_message() do
    case Settings.get_auto_policy() do
      {:deny, ms} when is_integer(ms) and ms > 0 ->
        seconds = div(ms, 1000)

        """
        The request was automatically denied after #{seconds} seconds due to an active auto-deny policy.
        The user may not be monitoring their terminal. Only use pre-approved shell commands that will not require user confirmation.
        """
        |> String.trim()

      _ ->
        @no_feedback
    end
  end

  defp edit?, do: Settings.get_edit_mode()
  defp auto?, do: edit?() && Settings.get_auto_approve()

  # ----------------------------------------------------------------------------
  # Public helpers for user-configured approvals (for display/spec composition)
  # ----------------------------------------------------------------------------

  @doc """
  Returns a sorted, de-duplicated list of user-configured prefix approvals
  for shell commands (kind: "shell") across both global and project scopes.
  """
  @spec list_user_prefixes() :: [String.t()]
  def list_user_prefixes do
    settings = Settings.new()

    global = Settings.Approvals.get_approvals(settings, :global, "shell")
    project = Settings.Approvals.get_approvals(settings, :project, "shell")

    global
    |> Enum.concat(project)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Returns a sorted, de-duplicated list of user-configured full-command regex
  approvals for shell commands (kind: "shell_full") across both global and
  project scopes.
  """
  @spec list_user_regexes() :: [String.t()]
  def list_user_regexes do
    settings = Settings.new()

    global = Settings.Approvals.get_approvals(settings, :global, "shell_full")
    project = Settings.Approvals.get_approvals(settings, :project, "shell_full")

    global
    |> Enum.concat(project)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.sort()
  end
end
