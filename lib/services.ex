defmodule Services do
  def start_all do
    start_external_services()
    start_internal_services()
  end

  defp start_external_services do
    {:ok, _} = Application.ensure_all_started(:briefly)
  end

  defp start_internal_services do
    Once.start_link()
    NotesServer.start_link()
    TaskServer.start_link()
    AI.Agent.Researcher.start_link()
  end
end
