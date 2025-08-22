defmodule Services.Approvals.EditMode do
  @behaviour Services.Approvals
  # ----------------------------------------------------------------------------
  # Globals
  # ----------------------------------------------------------------------------
  @opt_approve_once "You son of a bitch, I'm in"
  @opt_approve_session "You son of a... for this session"
  @opt_approve_project "You son of a... across the project"
  @opt_approve_global "You son of a... globally"
  @opt_approve_once_edit "Approve with pattern (edit)"
  @opt_approve_session_edit "Approve for session with pattern (edit)"
  @opt_approve_project_edit "Approve for project with pattern (edit)"
  @opt_approve_global_edit "Approve globally with pattern (edit)"
  @opt_deny "Deny"
  @opt_deny_feedback "Deny (with feedback)"

  # ----------------------------------------------------------------------------
  # Behavior Implementation
  # ----------------------------------------------------------------------------

  @impl Services.Approvals
  def init do
    settings = Settings.new()

    globals =
      settings
      |> Settings.get_approvals(:global)
      |> Enum.flat_map(fn {tag, approved} -> Enum.map(approved, &{tag, &1}) end)
      |> Enum.into(MapSet.new())

    %{
      session: MapSet.new(),
      globals: globals,
      auto: MapSet.new()
    }
  end

  @impl Services.Approvals
  def confirm(opts, state) do
    # Extract required parameters
    message = Keyword.fetch!(opts, :message)
    detail = Keyword.fetch!(opts, :detail)
    tag = Keyword.fetch!(opts, :tag)
    subject = Keyword.fetch!(opts, :subject)

    # Display the information box regardless of pre-approval status so that the
    # user can see what is actions are being requested.
    print_info_box(message, detail, tag, subject)

    # Bypass if already approved at any scope
    {approved?, state} = is_approved_internal?(tag, subject, state)

    if approved? do
      {{:ok, :approved}, state}
    else
      do_confirm(opts, tag, subject, state)
    end
  end

  @impl Services.Approvals
  def enable_auto_approval(tag, subject, state) do
    new_state = %{state | auto: MapSet.put(state.auto, {tag, subject})}
    {{:ok, :approved}, new_state}
  end

  # Handles the actual prompt workflow when approval is not yet recorded
  defp do_confirm(opts, tag, subject, state) do
    options = get_options(opts)

    # Collect user choice and dispatch
    IO.puts("")

    "Approve this request?"
    |> UI.choose(options)
    |> handle_response(tag, subject, state)
  end

  defp print_info_box(message, detail, tag, subject) do
    # Skip output in quiet mode (used for tests)
    if Application.get_env(:fnord, :quiet, false) do
      :ok
    else
      do_print_info_box(message, detail, tag, subject)
    end
  end

  defp do_print_info_box(message, detail, tag, subject) do
    IO.puts("")

    pattern_help =
      pattern_examples()
      |> Enum.map(fn [pattern, description] -> "• #{description}: \"#{pattern}\"" end)
      |> Enum.join("\n")
      |> then(
        &("Pattern Examples:\n" <>
            &1 <> "\n\nRegex Reference: https://hexdocs.pm/elixir/Regex.html")
      )

    [
      Owl.Data.tag("# Purpose\n\n", [:cyan, :bright]),
      detail,
      "\n\n",
      Owl.Data.tag("# Approval Scope\n\n", [:cyan, :bright]),
      tag,
      " :: ",
      subject,
      "\n\n",
      Owl.Data.tag("# Details\n\n", [:cyan, :bright]),
      message,
      "\n\n",
      Owl.Data.tag("# Pattern Support\n\n", [:cyan, :bright]),
      pattern_help
    ]
    |> Owl.Box.new(
      title: " PERMISSION REQUEST ",
      min_width: 80,
      padding: 1,
      horizontal_align: :left,
      border_tag: [:red, :bright]
    )
    |> Owl.IO.puts()
  end

  # Pattern-matched handlers for each response option
  defp handle_response(@opt_approve_once, _tag, _subject, state), do: {{:ok, :approved}, state}

  defp handle_response(@opt_approve_session, tag, subject, state),
    do: approve(:session, tag, subject, state)

  defp handle_response(@opt_approve_project, tag, subject, state),
    do: approve(:project, tag, subject, state)

  defp handle_response(@opt_approve_global, tag, subject, state),
    do: approve(:global, tag, subject, state)

  # Pattern editing handlers
  defp handle_response(@opt_approve_once_edit, _tag, subject, state) do
    case prompt_for_pattern(subject) do
      {:ok, _pattern} -> {{:ok, :approved}, state}
      error -> {error, state}
    end
  end

  defp handle_response(@opt_approve_session_edit, tag, subject, state) do
    case prompt_for_pattern(subject) do
      {:ok, pattern} -> approve(:session, tag, pattern, state)
      error -> {error, state}
    end
  end

  defp handle_response(@opt_approve_project_edit, tag, subject, state) do
    case prompt_for_pattern(subject) do
      {:ok, pattern} -> approve(:project, tag, pattern, state)
      error -> {error, state}
    end
  end

  defp handle_response(@opt_approve_global_edit, tag, subject, state) do
    case prompt_for_pattern(subject) do
      {:ok, pattern} -> approve(:global, tag, pattern, state)
      error -> {error, state}
    end
  end

  defp handle_response(@opt_deny_feedback, _tag, subject, state),
    do: {deny_with_feedback(subject), state}

  defp handle_response(@opt_deny, _tag, subject, state), do: {deny(subject), state}
  defp handle_response({:error, :no_tty}, _tag, subject, state), do: {auto_deny(subject), state}

  @impl Services.Approvals
  def is_approved?(tag, subject, state) do
    result =
      is_approved?(nil, :project, tag, subject) or
        [:pre, :session, :global]
        |> Enum.any?(&is_approved?(state, &1, tag, subject))

    {result, state}
  end

  # Internal helper that doesn't change state
  defp is_approved_internal?(tag, subject, state) do
    result =
      is_approved?(nil, :project, tag, subject) or
        [:pre, :session, :global]
        |> Enum.any?(&is_approved?(state, &1, tag, subject))

    {result, state}
  end

  @impl Services.Approvals
  def approve(:project, tag, subject, state) do
    with {:ok, project} <- Settings.get_selected_project() do
      Settings.new()
      |> Settings.add_approval(project, tag, subject)
    end

    {{:ok, :approved}, state}
  end

  def approve(:session, tag, subject, state) do
    new_state = %{state | session: MapSet.put(state.session, {tag, subject})}
    {{:ok, :approved}, new_state}
  end

  def approve(:global, tag, subject, state) do
    Settings.new()
    |> Settings.add_approval(:global, tag, subject)

    new_state = %{state | globals: MapSet.put(state.globals, {tag, subject})}
    {{:ok, :approved}, new_state}
  end

  # ----------------------------------------------------------------------------
  # Internals
  # ----------------------------------------------------------------------------

  defp is_approved?(state, :pre, tag, subject) do
    check_approval_set(state.auto, tag, subject)
  end

  defp is_approved?(state, :session, tag, subject) do
    check_approval_set(state.session, tag, subject)
  end

  defp is_approved?(state, :global, tag, subject) do
    check_approval_set(state.globals, tag, subject)
  end

  defp is_approved?(_state, :project, tag, subject) do
    with {:ok, project} <- Settings.get_selected_project() do
      Settings.new()
      |> Settings.is_approved?(project, tag, subject)
    else
      _ -> false
    end
  end

  # Helper function to check approval against a MapSet with pattern support
  defp check_approval_set(approval_set, tag, subject) do
    # First check for exact match (fast path)
    if MapSet.member?(approval_set, {tag, subject}) do
      true
    else
      # Check for pattern matches
      approval_set
      |> Enum.any?(fn
        {^tag, approved_subject} -> matches_pattern?(approved_subject, subject)
        _ -> false
      end)
    end
  end

  # Pattern examples used in help text and validation
  defp pattern_examples do
    [
      ["git log", "Exact match (matches only git log)"],
      ["m/git .*/", "Regex (matches all git commands)"],
      ["m/docker (build|ps)/", "Regex with alternation (docker build or ps)"],
      ["m/npm (?!publish).*/", "Complex (npm except publish)"],
      ["m/find\\s+(?!.*-exec\\b).*/", "Safe find (find without -exec)"],
      ["/usr/local/bin/foo", "Paths (absolute paths)"]
    ]
  end

  # Check if a subject matches an approved pattern
  defp matches_pattern?(approved_subject, actual_subject) do
    if String.starts_with?(approved_subject, "m/") and String.ends_with?(approved_subject, "/") do
      # It's a regex pattern - extract the pattern between m/ and /
      pattern = String.slice(approved_subject, 2..-2//1)

      case Regex.compile(pattern) do
        {:ok, regex} -> Regex.match?(regex, actual_subject)
        _ -> false
      end
    else
      # Plain string match (backward compatible)
      approved_subject == actual_subject
    end
  end

  # Prompt user to edit approval pattern
  defp prompt_for_pattern(default_subject) do
    examples_text =
      pattern_examples()
      |> Enum.map(fn [pattern, description] -> "    - #{description}: \"#{pattern}\"" end)
      |> Enum.join("\n")

    prompt_text = """

    Enter approval pattern (default: #{default_subject})

    Examples:
    #{examples_text}

    Regex Reference: https://hexdocs.pm/elixir/Regex.html

    Pattern: 
    """

    case UI.prompt(String.trim(prompt_text), default: default_subject) do
      {:error, reason} ->
        {:error, "Cannot get input: #{reason}"}

      pattern when is_binary(pattern) ->
        pattern = String.trim(pattern)

        # If empty, use default
        pattern = if pattern == "", do: default_subject, else: pattern

        # Validate regex if it's a pattern
        if String.starts_with?(pattern, "m/") do
          regex_pattern = String.slice(pattern, 2..-1//1)

          case Regex.compile(regex_pattern) do
            {:ok, _} -> {:ok, pattern}
            {:error, reason} -> {:error, "Invalid regex pattern: #{inspect(reason)}"}
          end
        else
          {:ok, pattern}
        end
    end
  end

  defp get_options(opts) do
    persistent = Keyword.get(opts, :persistent, true)

    project =
      with {:ok, project} <- Settings.get_selected_project() do
        project
      else
        _ -> nil
      end

    cond do
      persistent && !is_nil(project) ->
        [
          @opt_approve_once,
          @opt_approve_once_edit,
          @opt_approve_session,
          @opt_approve_session_edit,
          @opt_approve_project,
          @opt_approve_project_edit,
          @opt_approve_global,
          @opt_approve_global_edit,
          @opt_deny,
          @opt_deny_feedback
        ]

      persistent ->
        [
          @opt_approve_once,
          @opt_approve_once_edit,
          @opt_approve_session,
          @opt_approve_session_edit,
          @opt_approve_global,
          @opt_approve_global_edit,
          @opt_deny,
          @opt_deny_feedback
        ]

      true ->
        [
          @opt_approve_once,
          @opt_approve_once_edit,
          @opt_approve_session,
          @opt_approve_session_edit,
          @opt_deny,
          @opt_deny_feedback
        ]
    end
  end

  defp deny(subject) do
    {:error,
     """
     The user did not approve this request:
     > #{subject}
     """}
  end

  defp deny_with_feedback(subject) do
    feedback = UI.prompt("Opine away:")

    {:error,
     """
     The user did not approve this request:
     > #{subject}

     They provided the following feedback in response:
     > #{feedback}
     """}
  end

  defp auto_deny(subject) do
    {:error,
     """
     The user did not approve this request:
     > #{subject}

     This was automatically denied because the user is not in an interactive session.
     """}
  end
end
