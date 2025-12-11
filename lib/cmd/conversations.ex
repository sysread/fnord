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
            help: "Prune by age (days) or delete a specific conversation by ID",
            parser: :string
          ],
          query: [
            value_name: "QUERY",
            long: "--query",
            short: "-q",
            help: "Semantic search query",
            parser: :string
          ],
          limit: [
            value_name: "LIMIT",
            long: "--limit",
            short: "-l",
            help: "Max search results",
            parser: :integer,
            default: 5
          ]
        ]
      ]
    ]
  end

  @impl Cmd
  def run(%{prune: prune} = opts, _subcommands, _unknown)
      when is_integer(prune) or is_binary(prune) do
    with {:ok, project} <- Store.get_project() do
      case prune(opts, project) do
        :ok -> :ok
        {:error, :cancelled} -> UI.error("Operation cancelled.")
        {:error, :invalid_prune_value} -> UI.error("Invalid --prune value: #{prune}")
        {:error, :not_found} -> UI.error("Conversation #{prune} not found.")
      end
    else
      {:error, :project_not_set} ->
        UI.error("No project selected; use --project or run in a project directory.")
    end
  end

  @impl Cmd
  def run(%{query: query} = opts, _subcommands, _unknown) when is_binary(query) do
    with {:ok, project} <- Store.get_project() do
      search(opts, project)
    else
      {:error, :project_not_set} ->
        UI.error(
          "No project selected; please specify --project or run inside a project directory."
        )
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

  defp prune(%{prune: prune_str} = opts, project) when is_binary(prune_str) do
    case Integer.parse(prune_str) do
      {days, ""} ->
        prune(%{opts | prune: days}, project)

      _ ->
        prune_by_id(prune_str, project)
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
        to_delete
        |> Enum.each(fn conversation ->
          Store.Project.Conversation.delete(conversation)
          Store.Project.ConversationIndex.delete(project, conversation.id)
        end)

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

  defp prune_by_id(id, project) do
    conversation = Store.Project.Conversation.new(id, project)

    with true <- Store.Project.Conversation.exists?(conversation),
         {:ok, question} <- Store.Project.Conversation.question(conversation) do
      message =
        "Confirm deletion of conversation #{id} (\"#{question}\"). This action cannot be undone."

      if UI.confirm(message) do
        case Store.Project.Conversation.delete(conversation) do
          :ok ->
            Store.Project.ConversationIndex.delete(project, id)
            UI.info("Deleted conversation #{id}.")
            :ok

          {:error, :not_found} ->
            {:error, :not_found}
        end
      else
        UI.error("Operation cancelled for conversation #{id}.")
        {:error, :cancelled}
      end
    else
      _ ->
        UI.error("Conversation #{id} not found.")
        {:error, :not_found}
    end
  end

  defp display(_opts, project) do
    project
    |> Store.Project.conversations()
    |> case do
      [] ->
        UI.puts("No conversations found.")

      conversations ->
        conversations
        |> Enum.map(fn conversation ->
          %{
            id: conversation.id,
            timestamp: Store.Project.Conversation.timestamp(conversation),
            file: conversation.store_path,
            question: get_question(conversation),
            length: Store.Project.Conversation.num_messages(conversation)
          }
        end)
        |> Jason.encode!(pretty: true)
        |> UI.puts()
    end

    :ok
  end

  defp search(opts, project) do
    query = Map.get(opts, :query)
    limit = Map.get(opts, :limit, 5)

    case Search.Conversations.search(project, query, limit: limit) do
      {:ok, results} ->
        Enum.each(results, &UI.puts(print_search_row(&1)))
        :ok

      {:error, reason} ->
        UI.error("Search failed: #{inspect(reason)}")
    end
  end

  defp print_search_row(%{
         conversation_id: id,
         score: score,
         timestamp: timestamp,
         title: title,
         length: length
       }) do
    [
      format_score(score),
      format_timestamp(timestamp),
      to_string(length),
      to_string(id),
      truncate_title(title)
    ]
    |> Enum.join("\t")
  end

  defp truncate_title(title) when is_binary(title) do
    case String.split(title, "\n", parts: 2) do
      [first] -> first
      [first, _rest] -> first <> "..."
    end
  end

  defp format_score(score) when is_number(score) do
    :erlang.float_to_binary(score, decimals: 3)
  end

  defp format_timestamp(timestamp) do
    case timestamp do
      %DateTime{} ->
        unix = DateTime.to_unix(timestamp)

        {cmd, args} =
          case :os.type() do
            {:unix, :darwin} ->
              {"date", ["-r", to_string(unix), "+%Y-%m-%d %H:%M:%S"]}

            {:unix, _} ->
              {"date", ["-d", "@#{unix}", "+%Y-%m-%d %H:%M:%S"]}
          end

        case System.cmd(cmd, args, stderr_to_stdout: true) do
          {result, 0} -> String.trim(result)
          _ -> DateTime.to_string(timestamp)
        end

      other ->
        to_string(other)
    end
  end

  defp get_question(conversation) do
    with {:ok, question} <- Store.Project.Conversation.question(conversation) do
      question
    else
      {:error, :no_question} -> "(not found)"
    end
  end
end
