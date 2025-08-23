defmodule Services.Approvals.Edit do
  @behaviour Services.Approvals.Workflow
  alias Services.Approvals.Workflow

  @not_edit_mode """
  The application is not running in edit mode.
  The user must pass --edit to enable edit mode.
  """
  @no_tty """
  The application is not running in an interactive terminal.
  The user cannot respond to prompts, so they were unable to approve or deny the request.
  """
  @approve "Approve"
  @session "Approve for this session"
  @deny "Deny"
  @deny_feedback "Deny with feedback"
  @no_feedback "The user denied the request."

  @impl Workflow
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
      !edit?() -> {:denied, @not_edit_mode, state}
      auto?() -> {:approved, state}
      !interactive?() -> {:error, @no_tty, state}
      true -> prompt(state)
    end
  end

  def approved?(_, _), do: edit?() && auto?()

  defp prompt(state) do
    case UI.choose("Approve this request?", [@approve, @session, @deny, @deny_feedback]) do
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

  # local helpers
  defp edit?, do: Settings.get_edit_mode()
  defp auto?, do: edit?() && Settings.get_auto_approve()
  defp interactive?(), do: UI.is_tty?()

  defp get_feedback() do
    "Feedback:"
    |> UI.prompt()
    |> then(&"The user denied the request with the following feedback: #{&1}")
  end
end
