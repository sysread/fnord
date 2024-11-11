defmodule AI.Tools.ListFiles do
  @behaviour AI.Tools

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "list_files_tool",
        description: "list all files in the project database",
        parameters: %{
          type: "object",
          required: [],
          properties: %{}
        }
      }
    }
  end

  @impl AI.Tools
  def call(agent, _args) do
    status_id = UI.add_status("Listing files in project", agent.opts.project)

    Store.new(agent.opts.project)
    |> Store.list_files()
    |> Enum.join("\n")
    |> then(fn res ->
      UI.complete_status(status_id, :ok)
      {:ok, res}
    end)
  end
end
