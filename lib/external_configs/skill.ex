defmodule ExternalConfigs.Skill do
  @moduledoc """
  A parsed Agent Skill from a `SKILL.md` file.

  The SKILL.md format is shared between Claude Code and Cursor: a directory
  containing a required `SKILL.md` with YAML frontmatter (name + description
  at minimum) and a markdown body. The `flavor` field distinguishes which
  ecosystem the skill came from (`:claude` or `:cursor`) so we can present
  them under separate headings to the coordinator.

  ## Self-delegation opt-out

  External skills frequently exist as shims that delegate Claude Code or
  Cursor invocations back to fnord (`fnord ask -W . -q ...`). When fnord
  itself loads such a skill, the directionality is reversed and the agent
  shells out to a fresh fnord process - infinite recursion.

  Two fields mark a skill as "do not expose to fnord agents":

  - `:fnord_skip` - boolean; true iff the skill should be filtered before
    being offered to fnord's coordinator.
  - `:fnord_skip_reason` - `:frontmatter` (explicit opt-out via the
    `fnord_skip: true` frontmatter key) or `:body_invokes_fnord` (fallback
    body scan for `fnord ask` / `fnord-dev ask`), or nil when not skipped.

  An explicit `fnord_skip: false` in the frontmatter overrides the body scan.
  This lets a skill author opt back in if their SKILL.md legitimately
  references `fnord ask` in passing.
  """

  defstruct [
    :name,
    :description,
    :when_to_use,
    :body,
    :path,
    :flavor,
    :source,
    fnord_skip: false,
    fnord_skip_reason: nil
  ]

  @type flavor :: :claude | :cursor
  @type source :: :global | :project
  @type skip_reason :: :frontmatter | :body_invokes_fnord | nil

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t() | nil,
          when_to_use: String.t() | nil,
          body: String.t(),
          path: String.t(),
          flavor: flavor(),
          source: source(),
          fnord_skip: boolean(),
          fnord_skip_reason: skip_reason()
        }

  # Matches a shell invocation of `fnord ask` or `fnord-dev ask` regardless of
  # surrounding punctuation (backticks, code fences). Word boundaries keep
  # `xfnord ask` and `fnordask` from triggering. Case-sensitive: shell
  # commands are case-sensitive, and English prose like "Fnord ask" is
  # almost always the project name in a sentence, not a command.
  @fnord_invocation_re ~r/\bfnord(?:-dev)?\s+ask\b/

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
      trimmed_body = String.trim(body)
      {fnord_skip, fnord_skip_reason} = detect_fnord_skip(fm, trimmed_body)

      {:ok,
       %__MODULE__{
         name: name,
         description: description,
         when_to_use: when_to_use,
         body: trimmed_body,
         path: skill_path,
         flavor: flavor,
         source: source,
         fnord_skip: fnord_skip,
         fnord_skip_reason: fnord_skip_reason
       }}
    end
  end

  # Resolves the skip decision. Order:
  # 1. Explicit `fnord_skip: true` -> skip (reason :frontmatter).
  # 2. Explicit `fnord_skip: false` -> load, even if the body matches.
  # 3. Body invokes `fnord ask` -> skip (reason :body_invokes_fnord).
  # 4. Otherwise -> load.
  defp detect_fnord_skip(fm, body) do
    case fetch_bool(fm, "fnord_skip") do
      true -> {true, :frontmatter}
      false -> {false, nil}
      nil -> body_skip(body)
    end
  end

  defp body_skip(body) do
    if Regex.match?(@fnord_invocation_re, body) do
      {true, :body_invokes_fnord}
    else
      {false, nil}
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

  defp fetch_bool(fm, key) do
    case Map.get(fm, key) do
      true -> true
      false -> false
      "true" -> true
      "false" -> false
      _ -> nil
    end
  end
end
