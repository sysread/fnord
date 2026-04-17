defmodule ExternalConfigs.Agent do
  @moduledoc """
  A parsed Claude Code subagent definition from a single `.md` file under
  `~/.claude/agents/` or `<project>/.claude/agents/`.

  Agents are sibling to skills: a named, described capability with an
  instruction body. They differ in format (a single `.md` file instead
  of a directory with `SKILL.md`) and in intent: an agent is a role
  (system prompt + allowed tools + model hint) that Claude Code would
  delegate to, whereas a skill is a procedure to follow. Fnord doesn't
  have a subagent-delegation mechanism, so from the coordinator's
  perspective an agent is reference material: the body is guidance to
  internalize when the description matches the task.

  ## Data flow

  1. `ExternalConfigs.Loader.load_claude_agents/1` discovers `.md` files
     under the global and project agents dirs, calls `from_file/2` per
     entry, and caches the resulting list.
  2. `ExternalConfigs.Catalog.partition_agents/1` filters out agents
     whose `tools` list implies edit capability when fnord isn't in
     edit mode, then feeds the rest to the skills catalog prompt.
  3. The coordinator's bootstrap (`external_configs_msg/1`) appends the
     catalog as a system message; the `Frippery.log_external_skills`
     boot line prints the enabled agents' names.
  """

  defstruct [
    :name,
    :description,
    :tools,
    :model,
    :body,
    :path,
    :source
  ]

  @type source :: :global | :project

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t() | nil,
          tools: [String.t()],
          model: String.t() | nil,
          body: String.t(),
          path: String.t(),
          source: source()
        }

  @doc """
  Load an agent from a single `.md` file. The agent name is derived from
  the filename (without the `.md` extension) when no `name` key is set
  in frontmatter.
  """
  @spec from_file(String.t(), source()) :: {:ok, t} | {:error, term()}
  def from_file(path, source) when is_binary(path) do
    with {:ok, content} <- File.read(path),
         {:ok, %{frontmatter: fm, body: body}} <-
           ExternalConfigs.Frontmatter.parse(content) do
      name = fetch_string(fm, "name") || derive_name(path)
      description = fetch_string(fm, "description")
      tools = fetch_tools(fm, "tools")
      model = fetch_string(fm, "model")

      {:ok,
       %__MODULE__{
         name: name,
         description: description,
         tools: tools,
         model: model,
         body: String.trim(body),
         path: path,
         source: source
       }}
    end
  end

  defp derive_name(path) do
    path
    |> Path.basename()
    |> String.replace_suffix(".md", "")
  end

  defp fetch_string(fm, key) do
    case Map.get(fm, key) do
      v when is_binary(v) ->
        case String.trim(v) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  # `tools` is conventionally a comma-separated string; the Agent Skills
  # standard also allows a YAML list. Accept either.
  defp fetch_tools(fm, key) do
    case Map.get(fm, key) do
      nil ->
        []

      list when is_list(list) ->
        list
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      str when is_binary(str) ->
        str
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end
end
