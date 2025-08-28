defmodule Cmd.Conversations do
  @behaviour Cmd

  @impl Cmd
  def requires_project?(), do: true

  @impl Cmd
  def spec do
    [
      conversations: [
        name: "conversations",
        about: "List all conversations in the project",
        options: [
          project: Cmd.project_arg(),
          prune: [
            value_name: "PRUNE",
            long: "--prune",
            short: "-P",
            help: "Prune conversations older than this many days",
            parser: :integer
          ]
        ]
      ]
    ]
  end

  @impl Cmd
  def run(%{prune: days} = opts, _subcommands, _unknown) when is_integer(days) do
    with {:ok, project} <- Store.get_project() do
      case prune(opts, project) do
        :ok -> :ok
        {:error, :cancelled} -> UI.error("Operation cancelled.")
        {:error, :invalid_prune_value} -> UI.error("Invalid --prune value: #{days}")
      end
    else
      {:error, :project_not_set} ->
        UI.error("No project selected; use --project or run in a project directory.")
    end
  end

  @impl Cmd
  def run(opts, _subcommands, _unknown) do
    with {:ok, project} <- Store.get_project(),
         :ok <- display(opts, project) do
      :ok
    else
      {:error, :project_not_set} ->
        UI.error(
          "No project selected; please specify --project or run inside a project directory."
        )
    end
  end

  defp prune(%{prune: days}, project) when is_integer(days) and days >= 0 do
    cutoff = DateTime.utc_now() |> DateTime.add(-days, :day)

    UI.info("Pruning conversations older than #{days} days")

    to_delete =
      project
      |> Store.Project.conversations()
      |> Enum.reduce([], fn conversation, acc ->
        timestamp = Store.Project.Conversation.timestamp(conversation)

        if DateTime.compare(timestamp, cutoff) == :lt do
          [conversation | acc]
        else
          acc
        end
      end)

    if to_delete == [] do
      UI.info("No conversations to prune.")
      :ok
    else
      UI.info("Preparing to delete the following conversations:")

      to_delete
      |> Enum.each(fn conversation ->
        UI.info(conversation.id)
      end)

      if UI.confirm("Confirm deletion of the listed conversations. This action cannot be undone.") do
        to_delete |> Enum.each(&Store.Project.Conversation.delete/1)
        count = length(to_delete)
        UI.info("Deleted #{count} conversation(s).")
        :ok
      else
        {:error, :cancelled}
      end
    end
  end

  defp prune(%{prune: days}, _project) when is_integer(days) and days < 0 do
    {:error, :invalid_prune_value}
  end

  defp prune(_opts, _project), do: :ok

  defp display(_opts, project) do
    project
    |> Store.Project.conversations()
    |> case do
      [] ->
        IO.puts("No conversations found.")

      conversations ->
        conversations
        |> Enum.map(fn conversation ->
          %{
            id: conversation.id,
            timestamp: Store.Project.Conversation.timestamp(conversation),
            file: conversation.store_path,
            question: get_question(conversation)
          }
        end)
        |> Jason.encode!(pretty: true)
        |> IO.puts()
    end

    :ok
  end

  defp get_question(conversation) do
    with {:ok, question} <- Store.Project.Conversation.question(conversation) do
      question
    else
      {:error, :no_question} -> "(not found)"
    end
  end
end
