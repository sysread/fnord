defmodule Services do
  def start_all do
    start_external_services()
    start_internal_services()
  end

  defp start_external_services do
    {:ok, _} = Application.ensure_all_started(:briefly)
  end

  defp start_internal_services do
    # Start core services that don't depend on CLI configuration
    Services.Once.start_link()
    Services.Notes.start_link()
    Services.Task.start_link()
    AI.Agent.Researcher.start_link()
    Services.BackupFile.start_link()
    Services.Approvals.start_link()
    Services.ModelPerformanceTracker.start_link()
  end

  @doc """
  Starts the name pool service separately from other services.

  This service must be started AFTER set_globals() is called because it needs
  to read the configured workers setting to determine its batch allocation size.
  The workers setting is parsed from CLI arguments and set in set_globals().
  """
  def start_name_pool do
    Services.NamePool.start_link()
  end
end
