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

      if Enum.all?(stages, &approved?(state, &1)) do
        {:approved, state}
      else
        if !UI.is_tty?() do
          UI.error("Shell", @no_tty)
          {:denied, @no_tty, state}
        else
          render_pipeline(op, commands, purpose)
          prompt(state, stages)
        end
      end
    else
      {:error, reason} -> {:denied, reason, state}
    end
  end

  # ----------------------------------------------------------------------------
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
  @full_cmd [
    "^find(?!.*-exec)"
  ]

  @ro_cmd [
    "ag",
    "cat",
    "diff",
    "fgrep",
    "grep",
    "head",
    "jq",
    "ls",
    "nl",
    "pwd",
    "rg",
    "tac",
    "tail",
    "tr",
    "tree",
    "wc",

    # git subcommands
    "git branch",
    "git diff",
    "git grep",
    "git log",
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

  defp session_approvals(%{session: session}, kind) do
    session
    |> Enum.reduce([], fn
      {^kind, prefix}, acc -> [prefix | acc]
      _, acc -> acc
    end)
  end

  # Returns true if either the prefix path or the full command string is
  # approved or a stored full-command approval matches this stage.
  defp approved?(state, {prefix, full}) do
    prefix_approved?(state, prefix) or
      full_cmd_preapproved?(state, full)
  end

  def prefix_approved?(state, prefix) do
    cond do
      prefix in preapproved_cmds() -> true
      prefix in session_approvals(state, :prefix) -> true
      Settings.Approvals.approved?(Settings.new(), :project, "shell", prefix) -> true
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

  # ----------------------------------------------------------------------------
  # Display
  # ----------------------------------------------------------------------------
  defp render_pipeline(op, commands, purpose) do
    stages =
      commands
      |> Enum.map(&format_stage/1)
      |> Enum.with_index(1)
      |> Enum.map(fn {cmd, i} -> "#{i}. #{cmd}" end)
      |> Enum.join("\n\n")

    op_msg =
      case op do
        "|" -> "Pipeline of Commands"
        "&&" -> "Chained Commands"
      end

    [
      Owl.Data.tag("# Approval Scope ", [:red_background, :black, :bright]),
      "\n\n#{op_msg}:\n\n",
      stages,
      "\n\n",
      Owl.Data.tag("# Purpose ", [:red_background, :black, :bright]),
      "\n\n",
      purpose
    ]
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
    base = Path.basename(cmd)
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
        {:denied, @no_feedback, state}

      @deny_feedback ->
        {:denied, get_feedback(), state}

      @persistent ->
        customize(state, stages)
    end
  end

  @spec customize(state, [String.t()] | list({String.t(), String.t()})) :: {:approved, state}
  def customize(state, stages) do
    stages
    |> Enum.uniq()
    # Filter out already approved stages
    |> Enum.reject(fn {prefix, full} -> approved?(state, {prefix, full}) end)
    # Extract just the prefixes
    |> Enum.map(fn {prefix, _full} -> prefix end)
    # Iterate over each unapproved prefix and ask for scope or regex
    |> Enum.reduce({:approved, state}, fn prefix, {:approved, acc_state} ->
      {:approved, new_state} = choose_scope_with_optional_regex(acc_state, prefix)
      {:approved, new_state}
    end)
  end

  defp choose_scope_with_optional_regex(state, prefix) do
    scope =
      UI.choose(
        "Choose approval scope for: #{prefix}\n\n" <>
          "Tip: Enter a regex by enclosing it in slashes, e.g. '/^find(?!.*-exec).*$/'. " <>
          "Regex matches against the command basename with args.",
        [@session, @project, @global]
      )

    input =
      UI.prompt(
        "Enter a /<regex>/ (leave blank to approve prefix '#{prefix}'):",
        optional: true
      )

    trimmed = String.trim(input)

    cond do
      trimmed == "" ->
        approve_scope(scope, state, prefix)

      String.starts_with?(trimmed, "/") and String.ends_with?(trimmed, "/") ->
        inner = String.slice(trimmed, 1..-2//1)

        if inner == "" do
          UI.error("Empty regex is not allowed")
          approve_scope(scope, state, prefix)
        else
          case Regex.compile(inner, "u") do
            {:ok, _} ->
              approve_regex_scope(scope, state, inner, prefix)

            {:error, {msg, _pos}} ->
              UI.error("Invalid regex: #{to_string(msg)}")
              approve_scope(scope, state, prefix)
          end
        end

      true ->
        # Not slash-delimited, treat as approving the prefix
        approve_scope(scope, state, prefix)
    end
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

  # ----------------------------------------------------------------------------
  # Utilities
  # ----------------------------------------------------------------------------

  @doc """
  Delegate to the pure prefix extraction logic.
  """
  def extract_prefix(%{"command" => cmd, "args" => args}) do
    base_cmd = Path.basename(cmd)
    Services.Approvals.Shell.Prefix.extract(base_cmd, args)
  end

  # Prompt user for feedback when denying with feedback
  defp get_feedback do
    "Feedback:"
    |> UI.prompt()
    |> then(&"The user denied the request with the following feedback: #{&1}")
  end

  defp edit?, do: Settings.get_edit_mode()
  defp auto?, do: edit?() && Settings.get_auto_approve()
end
