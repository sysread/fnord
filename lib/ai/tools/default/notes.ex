defmodule AI.Tools.Default.Notes do
  @behaviour AI.Tools

  @impl AI.Tools
  def ui_note_on_request(%{"op" => "create", "text" => text}) do
    {"Creating note", String.slice(text, 0, 50) <> "..."}
  end

  def ui_note_on_request(%{"op" => "update", "text" => text}) do
    {"Updating note", String.slice(text, 0, 50) <> "..."}
  end

  def ui_note_on_request(%{"op" => "delete", "id" => id}) do
    {"Deleting note", id}
  end

  def ui_note_on_request(%{"op" => "search", "needle" => needle}) do
    {"Searching notes for", String.slice(needle, 0, 50) <> "..."}
  end

  @impl AI.Tools
  def ui_note_on_result(%{"op" => "create"}, result) do
    {"Note created", "ID: #{result}"}
  end

  def ui_note_on_result(%{"op" => "update"}, result) do
    {"Note updated", "ID: #{result}"}
  end

  def ui_note_on_result(%{"op" => "delete"}, result) do
    {"Note deleted", "ID: #{result}"}
  end

  def ui_note_on_result(%{"op" => "search"} = args, result) do
    {"Search results for '#{args["needle"]}'", result}
  end

  @impl AI.Tools
  def read_args(args) do
    args
    |> Map.fetch("op")
    |> case do
      {:ok, "create"} ->
        with {:ok, text} <- Map.fetch(args, "text") do
          {:ok, %{"op" => "create", "text" => String.trim(text)}}
        else
          _ -> {:error, :missing_argument, "text"}
        end

      {:ok, "update"} ->
        with {:ok, id} <- Map.fetch(args, "id"),
             {:ok, text} <- Map.fetch(args, "text") do
          {:ok, %{"op" => "update", "id" => String.trim(id), "text" => String.trim(text)}}
        else
          _ -> {:error, :missing_argument, "id, text"}
        end

      {:ok, "delete"} ->
        with {:ok, id} <- Map.fetch(args, "id") do
          {:ok, %{"op" => "delete", "id" => String.trim(id)}}
        else
          _ -> {:error, :missing_argument, "id"}
        end

      {:ok, "search"} ->
        with {:ok, needle} <- Map.fetch(args, "needle") do
          {:ok, %{"op" => "search", "needle" => String.trim(needle)}}
        else
          _ -> {:error, :missing_argument, "needle"}
        end

      :error ->
        {:error, :missing_argument, "op"}

      {:ok, other} when is_binary(other) ->
        {:error, :invalid_argument, "op"}
    end
  end

  @impl AI.Tools
  def spec do
    %{
      type: "function",
      function: %{
        name: "notes",
        description: """
        Add a note to your personal notes. This is useful for keeping track of
        important information or reminders.
        """,
        parameters: %{
          type: "object",
          required: ["op"],
          properties: %{
            op: %{
              type: "string",
              description: "Valid options: [create | update | delete | search]"
            },
            id: %{
              type: "string",
              description:
                "The ID of the note to update or delete. Required for update/delete operations."
            },
            text: %{
              type: "string",
              description: "The text of the note. Required for create/update operations."
            },
            needle: %{
              type: "string",
              description: """
              The text to search for in your notes.
              Returns a JSONL list of notes whose text contained the needle (case insensitive).
              Required for search operations.
              """
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(%{"op" => "create", "text" => text}) do
    with {:ok, id} <- Store.DefaultProject.Notes.create(text) do
      {:ok, "Note created succesfully (ID: #{id})"}
    end
  end

  def call(%{"op" => "update", "id" => id, "text" => text}) do
    with {:ok, id} <- Store.DefaultProject.Notes.update(id, text) do
      {:ok, "Note updated successfully (ID: #{id})"}
    end
  end

  def call(%{"op" => "delete", "id" => id}) do
    with {:ok, id} <- Store.DefaultProject.Notes.delete(id) do
      {:ok, "Note deleted successfully (ID: #{id})"}
    end
  end

  def call(%{"op" => "search", "needle" => needle}) do
    AI.Agent.Default.NotesSearch.get_response(%{needle: needle})
  end
end
