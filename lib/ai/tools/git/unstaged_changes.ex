defmodule AI.Tools.Git.UnstagedChanges do
  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: true

  @impl AI.Tools
  def is_available?, do: Git.is_available?()

  @impl AI.Tools
  def ui_note_on_request(_args), do: {"Unstaged changes", "Reading the diff of unstaged changes"}

  @impl AI.Tools
  def ui_note_on_result(_args, _result), do: nil

  @impl AI.Tools
  def read_args(args), do: {:ok, args}

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "git_unstaged_changes_tool",
        description: """
        Get the diff of unstaged changes in the current git repository.
        """,
        parameters: %{
          additionalProperties: false,
          type: "object",
          required: [],
          properties: %{}
        }
      }
    }
  end

  @impl AI.Tools
  def call(_args), do: Git.git_diff([])
end
