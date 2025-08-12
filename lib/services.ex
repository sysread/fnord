defmodule Services do
  def start_all do
    start_external_services()
    start_internal_services()
  end

  defp start_external_services do
    {:ok, _} = Application.ensure_all_started(:briefly)
  end

  defp start_internal_services do
    Services.Once.start_link()
    Services.Notes.start_link()
    Services.Task.start_link()
    AI.Agent.Researcher.start_link()
    Services.BackupFile.start_link()
    Services.Approvals.start_link()
  end
end
