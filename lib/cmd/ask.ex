defmodule Cmd.Ask do
  @project_not_found_error "Project not found; verify that the project has been indexed."

  def run(opts) do
    with :ok <- validate(opts) do
      opts =
        opts
        |> Map.put(:conversation, get_conversation(opts))
        |> maybe_set_show_work_flag()

      AI.Agent.Answers.get_response(AI.new(), opts)
    else
      {:error, :project_not_found} -> UI.error(@project_not_found_error)
    end
  end

  defp validate(_opts) do
    Store.get_project()
    |> Store.Project.exists_in_store?()
    |> case do
      true -> :ok
      false -> {:error, :project_not_found}
    end
  end

  defp get_conversation(%{follow: nil}) do
    Store.Conversation.new()
  end

  defp get_conversation(%{follow: conversation_id}) do
    Store.Conversation.new(conversation_id)
  end

  defp maybe_set_show_work_flag(opts) do
    if System.get_env("FNORD_SHOW_WORK", "false") in ["1", "true", "TRUE"] do
      Application.put_env(:fnord, :show_work, true)
      Map.put(opts, :show_work, true)
    else
      opts
    end
  end
end
