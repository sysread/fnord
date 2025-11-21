defmodule Services do
  def start_all do
    start_external_services()
    start_internal_services()
  end

  defp start_external_services do
    {:ok, _} = Application.ensure_all_started(:briefly)
  end

  defp start_internal_services do
    # Start Globals first, since it is the foundation for config.
    Services.Globals.start_link()

    # Start UI.Queue next, since other services may want to log messages
    # during their startup.
    UI.Queue.start_link()

    # Start core services that don't depend on CLI configuration
    Registry.start_link(keys: :unique, name: MCP.ClientRegistry)
    Services.Once.start_link()
    Services.Notes.start_link()
    Services.Memories.start_link()
    Services.Task.start_link()
    Services.Conversation.Interrupts.start_link([])
    AI.Agent.Researcher.start_link()
    Services.BackupFile.start_link()
  end

  @doc """
  Starts services that depend on CLI configuration.

  These services must be started AFTER set_globals() is called because they need
  to read configuration settings parsed from CLI arguments in set_globals().
  """
  def start_config_dependent_services(command \\ nil) do
    Services.NamePool.start_link()
    Services.Approvals.start_link()
    Services.Approvals.Gate.start_link([])
    Services.MCP.start(command)
    :ok
  end
end
