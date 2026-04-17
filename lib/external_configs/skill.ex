defmodule ExternalConfigs.Skill do
  @moduledoc """
  A parsed Agent Skill from a `SKILL.md` file.

  The SKILL.md format is shared between Claude Code and Cursor: a directory
  containing a required `SKILL.md` with YAML frontmatter (name + description
  at minimum) and a markdown body. The `flavor` field distinguishes which
  ecosystem the skill came from (`:claude` or `:cursor`) so we can present
  them under separate headings to the coordinator.
  """

  defstruct [
    :name,
    :description,
    :when_to_use,
    :body,
    :path,
    :flavor,
    :source
  ]

  @type flavor :: :claude | :cursor
  @type source :: :global | :project

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t() | nil,
          when_to_use: String.t() | nil,
          body: String.t(),
          path: String.t(),
          flavor: flavor(),
          source: source()
        }

  @doc """
  Load a skill from a directory containing `SKILL.md`.
  """
  @spec from_dir(String.t(), flavor(), source()) :: {:ok, t} | {:error, term()}
  def from_dir(dir, flavor, source) when is_binary(dir) do
    skill_path = Path.join(dir, "SKILL.md")

    with {:ok, content} <- File.read(skill_path),
         {:ok, %{frontmatter: fm, body: body}} <-
           ExternalConfigs.Frontmatter.parse(content) do
      name =
        fetch_string(fm, "name") ||
          dir |> Path.basename() |> String.downcase()

      description = fetch_string(fm, "description")
      when_to_use = fetch_string(fm, "when_to_use")

      {:ok,
       %__MODULE__{
         name: name,
         description: description,
         when_to_use: when_to_use,
         body: String.trim(body),
         path: skill_path,
         flavor: flavor,
         source: source
       }}
    end
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
end
