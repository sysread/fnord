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
    "truncate",
    "tr"
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

  def preapproved_cmds do
    if edit?() and auto?() do
      @ro_cmd ++ @rw_cmd
    else
      @ro_cmd
    end
  end

  # ----------------------------------------------------------------------------
  # Behaviour implementation
  # ----------------------------------------------------------------------------
  @behaviour Services.Approvals.Workflow

  @impl Services.Approvals.Workflow
  @spec confirm(state, args) :: decision
  def confirm(state, {op, commands, purpose}) when is_list(commands) do
    with :ok <- validate_commands(commands) do
      stages = Enum.map(commands, &extract_prefix/1)

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
  defp approved?(%{session: session}, prefix) do
    preapproved?(prefix) or
      Enum.any?(session, &(&1 == prefix)) or
      Settings.new() |> Settings.Approvals.approved?("shell", prefix)
  end

  defp preapproved?(prefix) do
    cond do
      prefix in preapproved_cmds() -> true
      true -> false
    end
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
      {:approved, new_state} = choose_scope(acc_state, prefix)
      {:approved, new_state}
    end)
  end

  defp choose_scope(state, prefix) do
    UI.choose("Choose approval scope for: #{prefix}", [@session, @project, @global])
    |> approve_scope(state, prefix)
  end

  defp approve_scope(@session, %{session: session} = state, prefix) do
    # store plain prefixes in-memory for this session
    prefixes = session |> Enum.concat([prefix]) |> Enum.uniq()
    {:approved, %{state | session: prefixes}}
  end

  defp approve_scope(@project, state, prefix) do
    # persist plain prefix; Settings will compile to regex on load
    Settings.new() |> Settings.Approvals.approve(:project, "shell", prefix)
    {:approved, state}
  end

  defp approve_scope(@global, state, prefix) do
    # persist plain prefix; Settings will compile to regex on load
    Settings.new() |> Settings.Approvals.approve(:global, "shell", prefix)
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

  defp get_feedback() do
    "Feedback:"
    |> UI.prompt()
    |> then(&"The user denied the request with the following feedback: #{&1}")
  end

  defp edit?, do: Settings.get_edit_mode()
  defp auto?, do: edit?() && Settings.get_auto_approve()
end
