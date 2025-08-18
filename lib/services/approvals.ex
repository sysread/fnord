defmodule Services.Approvals do
  # ----------------------------------------------------------------------------
  # Globals
  # ----------------------------------------------------------------------------
  @opt_approve_once "You son of a bitch, I'm in"
  @opt_approve_session "You son of a... for this session"
  @opt_approve_project "You son of a... across the project"
  @opt_approve_global "You son of a... globally"
  @opt_deny "Deny"
  @opt_deny_feedback "Deny (with feedback)"

  # ----------------------------------------------------------------------------
  # Service API
  # ----------------------------------------------------------------------------
  def start_link(opts \\ [name: __MODULE__]) do
    Agent.start_link(&init/0, opts)
  end

  @doc """
  Request approval for `tag` and `subject`. If auto-approved, session, project, or global approved,
  short-circuits without prompting UI. Otherwise prompts as before.
  """
  def confirm(opts, agent \\ __MODULE__) do
    # Extract required parameters
    message = Keyword.fetch!(opts, :message)
    detail = Keyword.fetch!(opts, :detail)
    tag = Keyword.fetch!(opts, :tag)
    subject = Keyword.fetch!(opts, :subject)

    # Auto-approve or bypass if already approved at any scope
    if Agent.get(agent, fn state -> MapSet.member?(state.auto, {tag, subject}) end) or
         is_approved?(tag, subject, agent) do
      {:ok, :approved}
    else
      do_confirm(message, detail, opts, tag, subject, agent)
    end
  end

  @doc """
  During this session, auto-approve the given `{tag, subject}` pair and bypass any future prompts.
  """
  @spec enable_auto_approval(String.t(), String.t(), atom() | pid()) :: :ok
  def enable_auto_approval(tag, subject, agent \\ __MODULE__) do
    Agent.update(agent, fn state ->
      %{state | auto: MapSet.put(state.auto, {tag, subject})}
    end)
  end

  # Handles the actual prompt workflow when approval is not yet recorded
  defp do_confirm(message, detail, opts, tag, subject, agent) do
    options = get_options(opts)

    # Display permission box
    Owl.IO.puts("")

    scope = """
    ## Persistent approval scope
    **Tag:** #{tag}
    **Subject:** #{subject}
    """

    [detail, scope]
    |> Enum.join("\n\n")
    |> Owl.Box.new(
      title: " PERMISSION REQUIRED ",
      min_width: 80,
      padding: 1,
      horizontal_align: :left
    )
    |> Owl.IO.puts()

    # Collect user choice and dispatch
    UI.choose(message, options)
    |> handle_response(tag, subject, agent)
  end

  # Pattern-matched handlers for each response option
  defp handle_response(@opt_approve_once, _tag, _subject, _agent), do: {:ok, :approved}

  defp handle_response(@opt_approve_session, tag, subject, agent),
    do: approve(:session, tag, subject, agent)

  defp handle_response(@opt_approve_project, tag, subject, agent),
    do: approve(:project, tag, subject, agent)

  defp handle_response(@opt_approve_global, tag, subject, agent),
    do: approve(:global, tag, subject, agent)

  defp handle_response(@opt_deny_feedback, _tag, subject, _agent), do: deny_with_feedback(subject)
  defp handle_response(@opt_deny, _tag, subject, _agent), do: deny(subject)
  defp handle_response({:error, :no_tty}, _tag, subject, _agent), do: auto_deny(subject)

  def is_approved?(tag, subject, agent \\ __MODULE__) do
    is_approved?(nil, :project, tag, subject) or
      Agent.get(agent, fn state ->
        is_approved?(state, :session, tag, subject) or
          is_approved?(state, :global, tag, subject)
      end)
  end

  def approve(scope, tag, subject, agent \\ __MODULE__)

  def approve(:project, tag, subject, _agent) do
    with {:ok, project} <- Settings.get_selected_project() do
      Settings.new()
      |> Settings.add_approval(project, tag, subject)
    end

    {:ok, :approved}
  end

  def approve(:session, tag, subject, agent) do
    Agent.update(agent, fn state ->
      %{state | session: MapSet.put(state.session, {tag, subject})}
    end)

    {:ok, :approved}
  end

  def approve(:global, tag, subject, agent) do
    Agent.update(agent, fn state ->
      Settings.new()
      |> Settings.add_approval(:global, tag, subject)

      %{state | globals: MapSet.put(state.globals, {tag, subject})}
    end)

    {:ok, :approved}
  end

  # ----------------------------------------------------------------------------
  # Internals
  # ----------------------------------------------------------------------------
  defp init do
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

  defp is_approved?(state, :session, tag, subject) do
    MapSet.member?(state.session, {tag, subject})
  end

  defp is_approved?(state, :global, tag, subject) do
    MapSet.member?(state.globals, {tag, subject})
  end

  defp is_approved?(_state, :project, tag, subject) do
    with {:ok, project} <- Settings.get_selected_project() do
      Settings.new()
      |> Settings.is_approved?(project, tag, subject)
    else
      _ -> false
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
          @opt_approve_session,
          @opt_approve_project,
          @opt_approve_global,
          @opt_deny,
          @opt_deny_feedback
        ]

      persistent ->
        [
          @opt_approve_once,
          @opt_approve_session,
          @opt_approve_global,
          @opt_deny,
          @opt_deny_feedback
        ]

      true ->
        [
          @opt_approve_once,
          @opt_approve_session,
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
