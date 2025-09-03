defmodule Services.Approvals.Edit do
  @behaviour Services.Approvals.Workflow

  @approve "Approve"
  @session "Approve for this session"
  @deny "Deny"
  @deny_feedback "Deny with feedback"

  @no_feedback "The user denied the request."

  @not_edit_mode """
  The application is not running in edit mode.
  The user must pass --edit to enable edit mode.
  """

  @no_tty """
  The application is not running in an interactive terminal.
  The user cannot respond to prompts, so they were unable to approve or deny the request.
  """

  @impl Services.Approvals.Workflow
  def confirm(state, {file, diff}) do
    [
      Owl.Data.tag("# Scope ", [:red_background, :black, :bright]),
      "\n\nedit :: all files\n\n",
      Owl.Data.tag("# Changes ", [:red_background, :black, :bright]),
      "\n\n",
      diff
    ]
    |> UI.box(
      title: " Edit #{file} ",
      min_width: 80,
      padding: 1,
      horizontal_align: :left,
      border_tag: [:red, :bright]
    )

    cond do
      !edit?() ->
        UI.warn("Edit #{file}", @not_edit_mode)
        {:denied, @not_edit_mode, state}

      auto?() ->
        UI.info("Edit #{file}", "Auto-approved (either --yes passed or approved for session)")
        {:approved, state}

      !interactive?() ->
        UI.error("Edit #{file}", @no_tty)
        {:error, @no_tty, state}

      true ->
        prompt(state)
    end
  end

  def approved?(_, _), do: edit?() && auto?()

  defp prompt(state) do
    opts = [@approve, @session, @deny, @deny_feedback]

    Settings.get_auto_policy()
    |> case do
      {:approve, ms} -> UI.choose("Approve this request?", opts, ms, @approve)
      {:deny, ms} -> UI.choose("Approve this request?", opts, ms, @deny)
      _ -> UI.choose("Approve this request?", opts)
    end
    |> case do
      @approve ->
        {:approved, state}

      @session ->
        Settings.set_auto_approve(true)
        {:approved, state}

      @deny ->
        {:denied, @no_feedback, state}

      @deny_feedback ->
        {:denied, get_feedback(), state}
    end
  end

  defp edit?, do: Settings.get_edit_mode()
  defp auto?, do: edit?() && Settings.get_auto_approve()
  defp interactive?(), do: UI.is_tty?()

  defp get_feedback() do
    "Feedback:"
    |> UI.prompt()
    |> then(&"The user denied the request with the following feedback: #{&1}")
  end
end
