defmodule AI.Tools.GitLog do
  @behaviour AI.Tools

  @impl AI.Tools
  def ui_note_on_request(args) do
    {"Inspcting git history", inspect(args)}
  end

  @impl AI.Tools
  def ui_note_on_result(_args, _result), do: nil

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "git_log_tool",
        description: """
        Retrieves the commit log for a git repository. This tool can be used to
        analyze recent changes, track when a feature or bug was introduced, or
        explore the history of a repository. It is important to remember that
        people often write commit messages in a way that is not always clear or
        informative; the git_show_tool can be used to inspect commits to
        determine the changes that were actually made.
        """,
        parameters: %{
          type: "object",
          required: [],
          properties: %{
            since: %{
              type: "string",
              description: """
              Filters commits to only include those made after the specified date.
              Accepts any date format supported by `git log --since`. Example: '2 weeks ago', '2023-01-01'.
              """
            },
            until: %{
              type: "string",
              description: """
              Filters commits to only include those made before the specified date.
              Accepts any date format supported by `git log --until`. Example: '2023-01-01'.
              """
            },
            author: %{
              type: "string",
              description: "Filters commits to only include those made by the specified author."
            },
            grep: %{
              type: "string",
              description: "Searches commit messages for the specified string or regex."
            },
            max_count: %{
              type: "integer",
              description: "Limits the number of commits to retrieve."
            },
            path: %{
              type: "string",
              description: "Limits the log to commits affecting the specified file or directory."
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(_agent, args) do
    args
    |> build_git_log_args()
    |> Git.git_log()
    |> format_response()
  end

  defp build_git_log_args(args) do
    args
    |> Enum.reduce(["-p"], fn
      {"since", since}, acc -> acc ++ ["--since", since]
      {"until", until}, acc -> acc ++ ["--until", until]
      {"author", author}, acc -> acc ++ ["--author", author]
      {"grep", grep}, acc -> acc ++ ["--grep", grep]
      {"max_count", max_count}, acc -> acc ++ ["--max-count", Integer.to_string(max_count)]
      {"path", path}, acc -> acc ++ ["--", path]
      _, acc -> acc
    end)
  end

  defp format_response({:ok, log}) do
    {:ok, "[git_log]\n#{log}"}
  end

  defp format_response({:error, error}) do
    {:ok, "[git_log]\nError: #{error}"}
  end
end
