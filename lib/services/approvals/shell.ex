defmodule Services.Approvals.Shell do
  @behaviour Services.Approvals.Workflow

  @approve "Approve"
  @customize "Customize"
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

  @preapproved [
    # Common utilities
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
    "touch",
    "tree",
    "wc",

    # Git specific subcommands
    "git branch",
    "git diff",
    "git grep",
    "git log",
    "git merge-base",
    "git show",
    "git status"
  ]

  @preapproved_re Enum.map(@preapproved, &"^#{&1}(?=\\s|$)")

  @impl Services.Approvals.Workflow
  def confirm(state, {cmd, purpose}) do
    [
      Owl.Data.tag("# Approval Scope ", [:red_background, :black, :bright]),
      "\n\nshell :: #{cmd}\n\n",
      Owl.Data.tag("Persistent approval includes variants starting with the same prefix.", [
        :italic
      ]),
      "\n\n",
      Owl.Data.tag("# Purpose ", [:red_background, :black, :bright]),
      "\n\n",
      purpose
    ]
    |> UI.box(
      title: " Shell Command ",
      min_width: 80,
      padding: 1,
      horizontal_align: :left,
      border_tag: [:red, :bright]
    )

    cond do
      approved?(state, cmd) -> {:approved, state}
      !UI.is_tty?() -> {:denied, @no_tty, state}
      true -> prompt(state, cmd)
    end
  end

  def approved?(%{session: session} = _state, cmd) do
    cond do
      preapproved?(cmd) -> true
      Enum.any?(session, &Regex.match?(&1, cmd)) -> true
      Settings.new() |> Settings.Approvals.approved?("shell", cmd) -> true
      true -> false
    end
  end

  defp preapproved?(cmd) do
    @preapproved_re
    |> Enum.map(&Regex.match?(&1, cmd))
  end

  def preapproved_cmds, do: @preapproved

  defp prompt(state, cmd) do
    case UI.choose("Approve this request?", [@approve, @customize, @deny, @deny_feedback]) do
      @approve -> {:approved, state}
      @deny -> {:denied, @no_feedback, state}
      @deny_feedback -> {:denied, get_feedback(), state}
      @customize -> customize(state, cmd)
    end
  end

  defp customize(state, cmd) do
    UI.newline()

    [
      Owl.Data.tag("# Instructions ", [:green_background, :black, :bright]),
      "\n\nCustomize the regular expression used to approve this command.\n\n",
      Owl.Data.tag("# Note ", [:green_background, :black, :bright]),
      "\n\n",
      Owl.Data.tag(
        "Complex shell commands with pipes/redirection/subshells always require explicit consent.",
        [:italic]
      ),
      "\n\n",
      Owl.Data.tag("# Default ", [:green_background, :black, :bright]),
      "\n\n",
      Owl.Data.tag("    #{cmd_to_pattern(cmd)} ", [:light_black_background, :yellow, :bright])
    ]
    |> Owl.Box.new(
      title: " Customize Shell Command Approval ",
      min_width: 80,
      padding: 1,
      horizontal_align: :left,
      border_tag: [:green, :bright]
    )
    |> Owl.IO.puts()

    get_shell_pattern(state, cmd)
  end

  defp get_shell_pattern(state, cmd) do
    case UI.prompt("Customize approval: ", optional: true) do
      nil ->
        confirm(state, {cmd, "User exited customization."})

      "" ->
        confirm(state, {cmd, "User exited customization."})

      pat ->
        case Regex.compile(pat) do
          {:ok, re} ->
            choose_scope(state, Regex.source(re))

          {:error, r} ->
            UI.error("Invalid regular expression", r)
            get_shell_pattern(state, cmd)
        end
    end
  end

  defp choose_scope(state, pattern) do
    UI.choose("Choose the scope of your approved shell command pattern: `#{pattern}`", [
      @session,
      @project,
      @global
    ])
    |> approve_scope(state, pattern)
  end

  defp approve_scope(@session, %{session: session} = state, pattern) do
    re = Regex.compile!(pattern)

    patterns =
      session
      |> Enum.concat([re])
      |> Enum.sort()
      |> Enum.uniq()

    {:approved, %{state | session: patterns}}
  end

  defp approve_scope(@project, state, pattern) do
    Settings.new() |> Settings.Approvals.approve(:project, "shell", pattern)
    {:approved, state}
  end

  defp approve_scope(@global, state, pattern) do
    Settings.new() |> Settings.Approvals.approve(:global, "shell", pattern)
    {:approved, state}
  end

  defp get_feedback() do
    "Feedback:"
    |> UI.prompt()
    |> then(&"The user denied the request with the following feedback: #{&1}")
  end

  defp cmd_to_pattern(cmd) do
    cmd
    |> String.trim_leading()
    |> Regex.escape()
    |> then(&"^#{&1}(?=\\s|$)")
  end
end
