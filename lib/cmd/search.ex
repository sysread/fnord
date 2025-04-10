defmodule Cmd.Search do
  @default_search_limit 10

  @behaviour Cmd

  @impl Cmd
  def spec do
    [
      search: [
        name: "search",
        about: "Perform a semantic search within a project",
        flags: [
          detail: [
            long: "--detail",
            help: "Include AI-generated file summary",
            default: false
          ]
        ],
        options: [
          project: [
            value_name: "PROJECT",
            long: "--project",
            short: "-p",
            help: "Project name",
            required: true
          ],
          query: [
            value_name: "QUERY",
            long: "--query",
            short: "-q",
            help: "Search query",
            required: true
          ],
          limit: [
            value_name: "LIMIT",
            long: "--limit",
            short: "-l",
            help: "Limit the number of results",
            parser: :integer,
            default: @default_search_limit
          ],
          workers: [
            value_name: "WORKERS",
            long: "--workers",
            short: "-w",
            help: "Limits the number of concurrent OpenAI requests",
            parser: :integer,
            default: Cmd.default_workers()
          ]
        ]
      ]
    ]
  end

  @impl Cmd
  def run(opts, _subcommands, _unknown) do
    opts
    |> Search.new()
    |> Search.get_results()
    |> Enum.each(fn {entry, score, data} ->
      if opts.detail do
        IO.puts("""
        -----
        # File: #{entry.file} | Score: #{score}
        #{data["summary"]}
        """)
      else
        IO.puts("#{score}\t#{entry.file}")
      end
    end)
  end
end
