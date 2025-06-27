defmodule AI.Tools.Default.Prompt do
  @behaviour AI.Tools

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def ui_note_on_request(%{"op" => "create"} = args), do: {"Creating prompt entry", args["text"]}
  def ui_note_on_request(%{"op" => "update"} = args), do: {"Updating prompt entry", args["text"]}
  def ui_note_on_request(%{"op" => "delete"} = args), do: {"Deleting prompt entry", args["id"]}

  @impl AI.Tools
  def ui_note_on_result(_args, result), do: {"Prompt modified successfully", inspect(result)}

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
        name: "prompt",
        description: """
        You are able to manage the instructions in your own system prompt using
        this tool. Each instruction in your system prompt is identified by an
        ID (displayed in angle brackets) which can be used to update or delete
        the entry later.
        """,
        parameters: %{
          type: "object",
          required: ["op"],
          properties: %{
            op: %{
              type: "string",
              description: "Valid options: [create | update | delete]"
            },
            id: %{
              type: "string",
              description:
                "The ID of the prompt instruction to update or delete. Required for update/delete operations."
            },
            text: %{
              type: "string",
              description:
                "The text of the prompt instruction. Required for create/update operations."
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(%{"op" => "create", "text" => text}) do
    with {:ok, id} <- Store.DefaultProject.Prompt.create(text) do
      {:ok, "Prompt entry created succesfully (ID: #{id})"}
    end
  end

  def call(%{"op" => "update", "id" => id, "text" => text}) do
    with {:ok, id} <- Store.DefaultProject.Prompt.update(id, text) do
      {:ok, "Prompt entry updated successfully (ID: #{id})"}
    end
  end

  def call(%{"op" => "delete", "id" => id}) do
    with {:ok, id} <- Store.DefaultProject.Prompt.delete(id) do
      {:ok, "Prompt entry deleted successfully (ID: #{id})"}
    end
  end
end
