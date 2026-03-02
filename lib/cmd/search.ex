defmodule Cmd.Search do
  @default_search_limit 10

  @behaviour Cmd

  @impl Cmd
  def requires_project?(), do: true

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
          project: Cmd.project_arg(),
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
          ]
        ]
      ]
    ]
  end

  @impl Cmd
  def run(opts, _subcommands, _unknown) do
    with {:ok, results} <- opts |> Search.Files.new() |> Search.Files.get_results() do
      results
      |> Enum.each(fn {entry, score, data} ->
        if opts.detail do
          UI.puts("""
          -----
          # File: #{entry.file} | Score: #{score}
          #{data["summary"]}
          """)
        else
          UI.puts("#{score}\t#{entry.file}")
        end
      end)
    else
      {:error, reason} ->
        UI.puts("Error: #{reason}")
    end
  end
end
