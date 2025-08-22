defmodule Services.Approvals.ReadOnlyMode do
  @moduledoc """
  Read-only mode implementation for approvals.

  In read-only mode:
  - Shell commands are only allowed if they match pre-approved patterns from AI.Tools.Shell.Allowed
  - File operations are always denied
  - No persistence or pattern editing is available
  """

  @behaviour Services.Approvals

  @impl Services.Approvals
  def init do
    # No state needed for read-only mode
    %{}
  end

  @impl Services.Approvals
  def confirm(opts, state) do
    # Extract required parameters
    message = Keyword.fetch!(opts, :message)
    detail = Keyword.fetch!(opts, :detail)
    tag = Keyword.fetch!(opts, :tag)
    subject = Keyword.fetch!(opts, :subject)

    # Display the information box so the user can see what was requested
    print_info_box(message, detail, tag, subject)

    case tag do
      "shell_cmd" ->
        # For shell commands, check if they're pre-approved
        if is_shell_command_allowed?(subject) do
          {{:ok, :approved}, state}
        else
          {deny_shell_command(subject), state}
        end

      "general" ->
        # File operations and other general operations are denied in read-only mode
        {deny_file_operation(subject), state}

      _ ->
        # Any other tag is denied
        {deny_unknown_operation(tag, subject), state}
    end
  end

  @impl Services.Approvals
  def is_approved?(tag, subject, state) do
    result =
      case tag do
        "shell_cmd" -> is_shell_command_allowed?(subject)
        _ -> false
      end

    {result, state}
  end

  @impl Services.Approvals
  def approve(_scope, _tag, _subject, state) do
    # No approvals are persisted in read-only mode
    {{:error, "Approval persistence not available in read-only mode"}, state}
  end

  @impl Services.Approvals
  def enable_auto_approval(_tag, _subject, state) do
    # No auto-approval in read-only mode
    {{:error, "Auto-approval not available in read-only mode"}, state}
  end

  # Private functions
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

    [
      Owl.Data.tag("PERMISSION REQUEST", [:red, :bright]),
      "\n\n",
      "Tag: #{tag}\n",
      "Subject: #{subject}\n\n",
      message,
      "\n\n",
      detail
    ]
    |> Owl.IO.puts()
  end

  defp is_shell_command_allowed?(subject) do
    # Parse the subject to get command and args
    case String.split(subject, " ", parts: 2) do
      [cmd | args_list] ->
        args = if args_list == [], do: [], else: String.split(hd(args_list), " ")
        approval_bits = [cmd | args]
        AI.Tools.Shell.Allowed.allowed?(cmd, approval_bits)

      [] ->
        false
    end
  end

  defp deny_shell_command(subject) do
    {:error,
     """
     > #{subject}

     Shell command denied in read-only mode. Only pre-approved commands are allowed.

     Use --edit mode to enable interactive command approval.
     """}
  end

  defp deny_file_operation(subject) do
    {:error,
     """
     > #{subject}

     File operation denied in read-only mode.

     Use --edit mode to enable file editing capabilities.
     """}
  end

  defp deny_unknown_operation(tag, subject) do
    {:error,
     """
     > #{subject} (tag: #{tag})

     Operation denied in read-only mode.

     Use --edit mode to enable interactive approval.
     """}
  end
end
