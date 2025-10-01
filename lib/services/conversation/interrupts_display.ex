defmodule Services.Conversation.InterruptsDisplay do
  @moduledoc """
  Production helper to display and clear queued user interrupts.

  This enables tests to exercise the same behavior through a production function,
  avoiding any test-only code paths in `lib/**`.
  """

  @type coord_state :: %{
          required(:conversation) => pid(),
          required(:pending_interrupts) => [map()],
          optional(any) => any
        }

  @spec display_pending_interrupts(coord_state) :: coord_state
  def display_pending_interrupts(%{pending_interrupts: interrupts} = state) do
    Enum.each(interrupts, fn msg ->
      # Strip internal prefix for display
      content = Map.get(msg, :content, "")
      display = String.replace_prefix(content, "[User Interjection] ", "")
      UI.info("You (rude)", display)
    end)

    # Clear the pending interrupts after displaying
    %{state | pending_interrupts: []}
  end
end
