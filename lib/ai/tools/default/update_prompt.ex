defmodule AI.Tools.Default.UpdatePrompt do
  @behaviour AI.Tools

  @impl AI.Tools
  def ui_note_on_request(%{"prompt" => prompt, "replace" => nil}) do
    {"Appending my system prompt", "'#{prompt}'"}
  end

  def ui_note_on_request(%{"prompt" => prompt, "replace" => replace}) do
    {"Modifying my system prompt", "s/#{replace}/#{prompt}/"}
  end

  @impl AI.Tools
  def ui_note_on_result(_args, _result), do: nil

  @impl AI.Tools
  def read_args(%{"prompt" => prompt} = args) do
    {:ok,
     %{
       "prompt" => prompt |> String.trim(),
       "replace" => Map.get(args, "replace", nil)
     }}
  end

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "update_prompt",
        description: """
        Update your own system prompt to change how you respond to user
        queries. This helps you evolve over time as you learn the user's
        personality and preferences.
        """,
        parameters: %{
          type: "object",
          required: ["prompt"],
          properties: %{
            prompt: %{
              type: "string",
              description: """
              New instructions that will be added to your prompt for your next
              interaction with the user.
              """
            },
            replace: %{
              type: "string",
              description: """
              A verbatim string from your existing system prompt to replace
              with the value of 'prompt'. You can use this to make surgical
              changes to your prompt without losing the rest of it, but it must
              be an exact match. Only the FIRST occurrence of the string will
              be replaced, so be careful to choose boundaries that ensure you
              only replace the part you want. This is also a good way to remove
              redundancy in your prompt, since you can replace the first
              occurrence of a phrase with an empty string.
              """
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(args) do
    with :ok <- update_prompt(args),
         {:ok, new_prompt} <- Store.DefaultProject.read_prompt() do
      {:ok,
       """
       Prompt updated successfully. Your updated prompt is:
       ```
       #{new_prompt}
       ```
       """}
    else
      {:error, reason} -> {:error, reason}
      :error -> {:error, "Missing required argument 'prompt'"}
    end
  end

  defp update_prompt(%{"prompt" => prompt, "replace" => nil}) do
    Store.DefaultProject.append_prompt(prompt)
  end

  defp update_prompt(%{"prompt" => prompt, "replace" => replace}) do
    Store.DefaultProject.modify_prompt(replace, prompt)
  end
end
