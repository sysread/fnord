defmodule AI.Tools.SelfHelp.Cli do
  @moduledoc """
  A tool that returns the fnord spec to the LLM to help it understand how to
  use the CLI and what commands are available. This allows the LLM to assist
  the user with questions about its own capabilities.
  """

  @behaviour AI.Tools

  @impl AI.Tools
  def async?(), do: false

  @impl AI.Tools
  def is_available?(), do: true

  @impl AI.Tools
  def ui_note_on_request(_), do: "Introspectively meditating on my purpose"

  @impl AI.Tools
  def ui_note_on_result(_, _), do: nil

  @impl AI.Tools
  def tool_call_failure_message(_, _), do: :default

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "fnord_help_cli_tool",
        description: """
        Retrieves the command specification for `fnord`, the code that is running your interface with the user.
        If the user asks about how "you work" or "your cli client works" or similar, use this tool to view the help text for your CLI wrapper.
        Fnord is written in elixir as an escript and uses Optimus for its CLI parsing.
        The help text will include the command tree, command descriptions, options, etc.
        Use that to understand how the CLI fits together and answer user questions about your interface and capabilities.
        """,
        parameters: %{
          type: "object",
          required: [],
          properties: %{}
        }
      }
    }
  end

  @impl AI.Tools
  def read_args(args), do: {:ok, args}

  @impl AI.Tools
  def call(_args) do
    Fnord.spec()
    |> inspect(limit: :infinity, pretty: true)
    |> then(&{:ok, "Spec for the `fnord` CLI (format: elixir Optimus spec):\n\n#{&1}"})
  end
end
