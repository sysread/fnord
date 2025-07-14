defmodule AI.Tools.Git.ListBranches do
  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: true

  @impl AI.Tools
  def is_available?, do: Git.is_available?()

  @impl AI.Tools
  def ui_note_on_request(_args), do: "Listing branches"

  @impl AI.Tools
  def ui_note_on_result(_args, _result), do: nil

  @impl AI.Tools
  def read_args(_args), do: {:ok, %{}}

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "git_list_branches_tool",
        description: "List all branches in the repository.",
        parameters: %{
          type: "object",
          required: [],
          properties: %{}
        }
      }
    }
  end

  @impl AI.Tools
  def call(_args) do
    with {:ok, output} <- Git.list_branches() do
      {:ok, "[git_list_branches]\n#{output}"}
    end
  end
end
