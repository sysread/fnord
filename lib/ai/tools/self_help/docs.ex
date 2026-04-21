defmodule AI.Tools.SelfHelp.Docs do
  @moduledoc """
  Searches fnord's published documentation to answer questions about features,
  configuration, and usage patterns. Uses a web-search-capable model scoped to
  fnord's canonical documentation sites.
  """

  @behaviour AI.Tools

  # Build canonical URL lists from docs/user/ at compile time so adding a
  # new user-facing guide automatically expands the search scope without
  # editing this module. Dev docs under docs/dev/ are intentionally out
  # of scope: they're architecture notes for contributors/LLMs working
  # on fnord itself, not answers to end-user questions.
  #
  # docs/user/README.md is NOT in hexdocs extras (see mix.exs - it's
  # excluded to avoid a `readme.html` filename collision with the top-level
  # README.md), so a URL for it would 404. The root README is already
  # represented as the hardcoded `readme.html` entry below; drop the
  # docs/user/README.md duplicate from the glob before building URLs.
  @doc_paths Path.wildcard("docs/user/*.md")
             |> Enum.reject(&(&1 == "docs/user/README.md"))
             |> Enum.sort()
  for path <- @doc_paths, do: @external_resource(path)

  @hexdocs_urls [
                  "- https://hexdocs.pm/fnord/readme.html"
                  | Enum.map(@doc_paths, fn path ->
                      "- https://hexdocs.pm/fnord/#{Path.basename(path, ".md")}.html"
                    end)
                ]
                |> Enum.join("\n")

  @github_urls [
                 "- https://github.com/sysread/fnord/blob/main/README.md"
                 | Enum.map(@doc_paths, fn path ->
                     "- https://github.com/sysread/fnord/blob/main/#{path}"
                   end)
               ]
               |> Enum.join("\n")

  @system_prompt """
  You are a documentation lookup tool for fnord, an AI-powered CLI for codebase research and editing.

  Start with these canonical sources.

  Hexdocs (preferred):
  #{@hexdocs_urls}

  GitHub (fallback):
  #{@github_urls}

  Follow links from these pages when the answer requires it.

  GitHub's web UI URLs sometimes fail to load. When fetching content from GitHub,
  convert to raw URLs. For example:
    https://github.com/sysread/fnord/blob/main/docs/user/README.md
  becomes:
    https://raw.githubusercontent.com/sysread/fnord/refs/heads/main/docs/user/README.md

  Provide a direct, concise answer based on the documentation content.
  Include inline citations (page titles or URLs) when referencing specific information.
  If the documentation does not cover the question, say so explicitly.
  """

  @impl AI.Tools
  def async?(), do: true

  @impl AI.Tools
  def is_available?(), do: true

  @impl AI.Tools
  def ui_note_on_request(%{"question" => q}), do: {"Researching fnord docs", q}
  def ui_note_on_request(_), do: "Researching fnord docs"

  @impl AI.Tools
  def ui_note_on_result(_, _), do: nil

  @impl AI.Tools
  def tool_call_failure_message(_, _), do: :default

  @impl AI.Tools
  def spec do
    %{
      type: "function",
      function: %{
        name: "fnord_help_docs_tool",
        description: """
        Search fnord's published documentation to answer questions about features, configuration, and usage.
        Use this tool when the user asks about how fnord works, what a feature does, or how to configure something.
        For CLI structure questions (flags, subcommands, command tree), prefer fnord_help_cli_tool instead.
        """,
        parameters: %{
          type: "object",
          additionalProperties: false,
          required: ["question"],
          properties: %{
            "question" => %{
              type: "string",
              description: "The question to research in fnord's documentation."
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def read_args(args), do: {:ok, args}

  @impl AI.Tools
  def call(args) do
    with {:ok, question} <- AI.Tools.get_arg(args, "question") do
      search_docs(question)
    end
  end

  defp search_docs(question) do
    AI.Completion.get(
      model: AI.Model.web_search(),
      messages: [
        AI.Util.system_msg(@system_prompt),
        AI.Util.user_msg(question)
      ]
    )
    |> case do
      {:ok, %{response: response}} ->
        {:ok, response}

      # Completion exposes the usage count alongside :context_length_exceeded;
      # collapsing it to an :error with a descriptive reason keeps the tool
      # caller contract single-shaped without dropping signal for logs.
      {:error, :context_length_exceeded, _usage} ->
        {:error, "documentation research exceeded the context window"}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
