defmodule Cmd.Ask do
  @project_not_found_error "Project not found; verify that the project has been indexed."

  def run(opts) do
    with :ok <- validate(opts) do
      AI.Agent.Answers.perform(AI.new(), opts)
    else
      {:error, :project_not_found} -> UI.error(@project_not_found_error)
    end
  end

  defp validate(_opts) do
    cond do
      !Store.project_exists?() -> {:error, :project_not_found}
      true -> :ok
    end
  end
end
