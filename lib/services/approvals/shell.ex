defmodule Services.Approvals.Shell do
  @behaviour Services.Approvals.Workflow

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

  @preapproved [
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
    "git show",
    "git status"
  ]

  @subcmd_families ~w/
    aws
    az
    brew
    cargo
    docker
    gcloud
    gh
    git
    go
    helm
    just
    kubectl
    make
    mix
    npm
    pip
    pip3
    pnpm
    poetry
    rye
    terraform
    uv
    yarn
  /

  @impl Services.Approvals.Workflow
  def confirm(state, {commands, purpose}) when is_list(commands) do
    stages = Enum.map(commands, &extract_prefix/1)

    if Enum.all?(stages, &approved?(state, &1)) do
      {:approved, state}
    else
      if !UI.is_tty?() do
        UI.error("Shell", @no_tty)
        {:denied, @no_tty, state}
      else
        render_pipeline(commands, purpose)
        prompt(state, stages)
      end
    end
  end

  def preapproved_cmds, do: @preapproved

  # ----------------------------------------------------------------------------
  # Approval checks
  # ----------------------------------------------------------------------------
  defp approved?(%{session: session}, prefix) do
    preapproved?(prefix) or
      Enum.any?(session, &Regex.match?(&1, prefix)) or
      Settings.new() |> Settings.Approvals.approved?("shell", prefix)
  end

  defp preapproved?(prefix) do
    @preapproved
    |> Enum.map(&Regex.compile!("^" <> Regex.escape(&1) <> "$"))
    |> Enum.any?(&Regex.match?(&1, prefix))
  end

  # ----------------------------------------------------------------------------
  # Display
  # ----------------------------------------------------------------------------
  defp render_pipeline(commands, purpose) do
    stages =
      commands
      |> Enum.map(&format_stage/1)
      |> Enum.with_index(1)
      |> Enum.map(fn {cmd, i} -> "#{i}. #{cmd}" end)
      |> Enum.join("\n\n")

    [
      Owl.Data.tag("# Approval Scope ", [:red_background, :black, :bright]),
      "\n\nPipeline of commands:\n\n",
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

  # ----------------------------------------------------------------------------
  # Prompt + persistence
  # ----------------------------------------------------------------------------
  defp prompt(state, stages) do
    case UI.choose("Approve this request?", [@approve, @persistent, @deny, @deny_feedback]) do
      @approve -> {:approved, state}
      @deny -> {:denied, @no_feedback, state}
      @deny_feedback -> {:denied, get_feedback(), state}
      @persistent -> customize(state, stages)
    end
  end

  defp customize(state, stages) do
    Enum.reduce(stages, {:approved, state}, fn prefix, {:approved, acc_state} ->
      {:approved, new_state} = choose_scope(acc_state, prefix_to_pattern(prefix))
      {:approved, new_state}
    end)
  end

  defp choose_scope(state, pattern) do
    UI.choose("Choose approval scope for: #{pattern}", [@session, @project, @global])
    |> approve_scope(state, pattern)
  end

  defp approve_scope(@session, %{session: session} = state, pattern) do
    case Regex.compile(pattern) do
      {:ok, re} ->
        patterns = session |> Enum.concat([re]) |> Enum.uniq()
        {:approved, %{state | session: patterns}}

      {:error, reason} ->
        UI.error("Invalid regular expression", reason)
        choose_scope(state, pattern)
    end
  end

  defp approve_scope(@project, state, pattern) do
    Settings.new() |> Settings.Approvals.approve(:project, "shell", pattern)
    {:approved, state}
  end

  defp approve_scope(@global, state, pattern) do
    Settings.new() |> Settings.Approvals.approve(:global, "shell", pattern)
    {:approved, state}
  end

  # ----------------------------------------------------------------------------
  # Utilities
  # ----------------------------------------------------------------------------

  defp extract_prefix(%{"command" => cmd, "args" => args}) do
    {_opts, argv_rest, _invalid} = OptionParser.parse(args, strict: [])

    if cmd in @subcmd_families do
      sub = argv_rest |> Enum.drop_while(&String.starts_with?(&1, "-")) |> List.first()

      if is_binary(sub) and sub != "" do
        cmd <> " " <> sub
      else
        cmd
      end
    else
      cmd
    end
  end

  defp prefix_to_pattern(prefix) do
    "^" <> Regex.escape(prefix) <> "$"
  end

  defp get_feedback() do
    "Feedback:"
    |> UI.prompt()
    |> then(&"The user denied the request with the following feedback: #{&1}")
  end
end
