defmodule Fnord do
  @moduledoc """
  Fnord is a code search tool that uses OpenAI's embeddings API to index and
  search code files.
  """

  @default_concurrency 8
  @default_search_limit 10

  @doc """
  Main entry point for the application. Parses command line arguments and
  dispatches to the appropriate subcommand.
  """
  def main(args) do
    {:ok, _} = Application.ensure_all_started(:briefly)

    configure_logger()

    with {:ok, subcommand, opts} <- parse_options(args) do
      opts = set_globals(opts)

      case subcommand do
        :index -> Cmd.Indexer.new(opts) |> Cmd.Indexer.run()
        :ask -> Cmd.Ask.run(opts)
        :search -> Cmd.Search.run(opts)
        :summary -> Cmd.Summary.run(opts)
        :torch -> Cmd.Torch.run(opts)
        :projects -> Cmd.Projects.run(opts)
        :files -> Cmd.Files.run(opts)
        :upgrade -> Cmd.Upgrade.run(opts)
        :review -> Cmd.Review.run(opts)
        :conversations -> Cmd.Conversations.run(opts)
      end
    else
      {:error, reason} -> IO.puts("Error: #{reason}")
    end
  end

  defp parse_options(args) do
    project = [
      value_name: "PROJECT",
      long: "--project",
      short: "-p",
      help: "Project name",
      required: true
    ]

    directory = [
      value_name: "DIR",
      long: "--dir",
      short: "-d",
      help: "Directory to index (required for first index or reindex after moving the project)",
      required: false
    ]

    reindex = [
      long: "--reindex",
      short: "-r",
      help: "Reindex the project",
      default: false
    ]

    quiet = [
      long: "--quiet",
      short: "-Q",
      help: "Suppress interactive output; automatically enabled when executed in a pipe",
      required: false,
      default: false
    ]

    query = [
      value_name: "QUERY",
      long: "--query",
      short: "-q",
      help: "Search query",
      required: true
    ]

    limit = [
      value_name: "LIMIT",
      long: "--limit",
      short: "-l",
      help: "Limit the number of results",
      default: @default_search_limit
    ]

    detail = [
      long: "--detail",
      help: "Include AI-generated file summary",
      default: false
    ]

    file = [
      value_name: "FILE",
      long: "--file",
      short: "-f",
      help: "File to summarize",
      required: true
    ]

    concurrency = [
      value_name: "WORKERS",
      long: "--concurrency",
      short: "-c",
      help: "Number of concurrent threads to use",
      parser: :integer,
      default: @default_concurrency
    ]

    question = [
      value_name: "QUESTION",
      long: "--question",
      short: "-q",
      help: "The prompt to ask the AI",
      required: true
    ]

    relpath = [
      long: "--relpath",
      short: "-r",
      help: "Print paths relative to $CWD",
      default: false
    ]

    yes = [
      long: "--yes",
      short: "-y",
      help: "Automatically answer 'yes' to all prompts",
      default: false
    ]

    include = [
      value_name: "FILE",
      long: "--include",
      short: "-i",
      help: "Include a file in your prompt",
      multiple: true
    ]

    exclude = [
      value_name: "FILE",
      long: "--exclude",
      short: "-x",
      help:
        "Exclude a file, directory, or glob from being indexed; this is stored in the project's configuration and used on subsequent indexes",
      multiple: true
    ]

    topic = [
      value_name: "TOPIC_BRANCH",
      long: "--topic",
      short: "-t",
      help: "The topic branch",
      required: true
    ]

    base = [
      value_name: "BASE_BRANCH",
      long: "--base",
      short: "-b",
      help: "The base branch (default: main)",
      default: "main",
      required: true
    ]

    show_work =
      [
        long: "--show-work",
        short: "-s",
        help: "Display tool call results; enable by default by setting FNORD_SHOW_WORK"
      ]

    follow = [
      long: "--follow",
      short: "-f",
      help: "Follow up the conversation with another question/prompt"
    ]

    parser =
      Optimus.new!(
        name: "fnord",
        description: "fnord - intelligent code index and search",
        allow_unknown_args: false,
        version: get_version(),
        subcommands: [
          index: [
            name: "index",
            about: "Index a project",
            options: [
              directory: directory,
              project: project,
              concurrency: concurrency,
              exclude: exclude
            ],
            flags: [
              reindex: reindex,
              quiet: quiet
            ]
          ],
          ask: [
            name: "ask",
            about: "Ask the AI a question about the project",
            options: [
              project: project,
              question: question,
              concurrency: concurrency,
              include: include,
              follow: follow
            ],
            flags: [
              show_work: show_work,
              replay: [
                long: "--replay",
                short: "-r",
                help: "Replay a conversation (with --follow is set)"
              ]
            ]
          ],
          review: [
            name: "review",
            about:
              "Review a topic branch against another branch. This always uses the remote branches on origin.",
            options: [project: project, concurrency: concurrency, topic: topic, base: base],
            flags: [quiet: quiet, show_work: show_work]
          ],
          conversations: [
            name: "conversations",
            about: "List all conversations in the project",
            options: [project: project],
            flags: [
              file: [
                long: "--file",
                short: "-f",
                help: "Print the path to the conversation file"
              ],
              question: [
                long: "--question",
                short: "-q",
                help: "include the question prompting the conversation"
              ]
            ]
          ],
          search: [
            name: "search",
            about: "Perform a semantic search within a project",
            options: [project: project, query: query, limit: limit, concurrency: concurrency],
            flags: [detail: detail]
          ],
          summary: [
            name: "summary",
            about: "Retrieve the AI-generated file summary used when indexing the file",
            options: [project: project, file: file]
          ],
          projects: [
            name: "projects",
            about: "Lists all projects",
            options: []
          ],
          files: [
            name: "files",
            about: "Lists all indexed files in a project",
            options: [project: project],
            flags: [relpath: relpath]
          ],
          torch: [
            name: "torch",
            about: "Deletes a previously indexed project from the database",
            options: [project: project]
          ],
          upgrade: [
            name: "upgrade",
            about: "Upgrade fnord to the latest version",
            flags: [yes: yes]
          ]
        ]
      )

    with {[subcommand], result} <- Optimus.parse!(parser, args) do
      options =
        result.args
        |> Map.merge(result.options)
        |> Map.merge(result.flags)

      {:ok, subcommand, options}
    else
      _ -> {:error, "missing or unknown subcommand"}
    end
  end

  defp get_version do
    {:ok, vsn} = :application.get_key(:fnord, :vsn)
    to_string(vsn)
  end

  def configure_logger do
    {:ok, handler_config} = :logger.get_handler_config(:default)
    updated_config = Map.update!(handler_config, :config, &Map.put(&1, :type, :standard_error))

    :ok = :logger.remove_handler(:default)
    :ok = :logger.add_handler(:default, :logger_std_h, updated_config)

    :ok =
      :logger.update_formatter_config(
        :default,
        :template,
        ["[", :level, "] ", :message, "\n"]
      )

    logger_level =
      System.get_env("LOGGER_LEVEL", "info")
      |> String.to_existing_atom()

    :ok = :logger.set_primary_config(:level, logger_level)
  end

  defp set_globals(args) do
    args
    |> Enum.each(fn
      {:concurrency, concurrency} ->
        Application.put_env(:fnord, :concurrency, concurrency)

      {:project, project} ->
        Application.put_env(:fnord, :project, project)

      {:quiet, quiet} ->
        Application.put_env(:fnord, :quiet, quiet)

      {:show_work, show_work} ->
        Application.put_env(:fnord, :show_work, show_work)

      _ ->
        :ok
    end)

    # --------------------------------------------------------------------------
    # When not connected to a TTY, the --quiet flag is automatically enabled,
    # unless the user explicitly specifies it.
    # --------------------------------------------------------------------------
    cond do
      args[:quiet] -> args
      IO.ANSI.enabled?() -> args
      true -> Map.put(args, :quiet, true)
    end
  end
end
