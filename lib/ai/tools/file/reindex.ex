defmodule AI.Tools.File.Reindex do
  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: true

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "file_reindex_tool",
        description: """
        Reindexes the entire project database, forcing a full rebuild of the
        index. This ensures that the search index used by the semantic search
        tool (file_search_tool) is up-to-date with all files in the project,
        including any new or modified files.
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
  def is_available?(), do: true

  @impl AI.Tools
  def ui_note_on_request(_args) do
    {"Re-index", "Updating semantic search index. This may take a moment."}
  end

  @impl AI.Tools
  def ui_note_on_result(_args, _result) do
    {"Re-index", "Complete"}
  end

  @impl AI.Tools
  def tool_call_failure_message(_args, _reason), do: :default

  @impl AI.Tools
  def read_args(_input), do: {:ok, %{}}

  @impl AI.Tools
  def call(_args) do
    Cmd.Index.run_as_tool_call(%{reindex: false, yes: true, quiet: true})
    {:ok, "Full reindex complete"}
  end
end
