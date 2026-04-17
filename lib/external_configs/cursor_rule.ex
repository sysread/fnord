defmodule ExternalConfigs.CursorRule do
  @moduledoc """
  A parsed Cursor rule (`.mdc` file or legacy `.cursorrules`).

  Cursor rules have four application modes determined by which frontmatter
  fields are set:

    * `:always`          - `alwaysApply: true`. Injected unconditionally.
    * `:auto_attached`   - `globs` non-empty. Injected when a file already
      in the chat context matches one of the globs (fnord triggers on file
      read/write).
    * `:agent_requested` - `description` set, no globs, not always. The
      model sees the description and chooses whether to fetch.
    * `:manual`          - none of the above. Only fetched on explicit
      request.

  Legacy `.cursorrules` files at the project root are treated as a single
  `:always` rule.
  """

  defstruct [
    :name,
    :description,
    :globs,
    :always_apply,
    :body,
    :path,
    :source,
    :mode
  ]

  @type source :: :global | :project | :legacy
  @type mode :: :always | :auto_attached | :agent_requested | :manual

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t() | nil,
          globs: [String.t()],
          always_apply: boolean(),
          body: String.t(),
          path: String.t(),
          source: source(),
          mode: mode()
        }

  @doc """
  Load a `.mdc` rule file. The rule name is derived from the file basename
  (without the `.mdc` extension).
  """
  @spec from_file(String.t(), source()) :: {:ok, t} | {:error, term()}
  def from_file(path, source) when is_binary(path) do
    with {:ok, content} <- File.read(path),
         {:ok, %{frontmatter: fm, body: body}} <-
           ExternalConfigs.Frontmatter.parse(content) do
      name = derive_name(path)

      description = fetch_string(fm, "description")
      globs = fetch_globs(fm, "globs")
      always_apply = fetch_bool(fm, "alwaysApply", false)

      {:ok,
       %__MODULE__{
         name: name,
         description: description,
         globs: globs,
         always_apply: always_apply,
         body: String.trim(body),
         path: path,
         source: source,
         mode: classify(always_apply, globs, description)
       }}
    end
  end

  @doc """
  Load a legacy `.cursorrules` file as a single `:always` rule. The body is
  the full file contents (there is no frontmatter in the legacy format).
  """
  @spec from_legacy_file(String.t()) :: {:ok, t} | {:error, term()}
  def from_legacy_file(path) when is_binary(path) do
    with {:ok, content} <- File.read(path) do
      {:ok,
       %__MODULE__{
         name: ".cursorrules",
         description: nil,
         globs: [],
         always_apply: true,
         body: String.trim(content),
         path: path,
         source: :legacy,
         mode: :always
       }}
    end
  end

  @doc """
  Returns true when any of the rule's globs match the given path (relative
  to the project source root).
  """
  @spec matches_path?(t, String.t()) :: boolean()
  def matches_path?(%__MODULE__{globs: []}, _path), do: false

  def matches_path?(%__MODULE__{globs: globs}, path) when is_binary(path) do
    Enum.any?(globs, &glob_match?(&1, path))
  end

  defp classify(true, _globs, _desc), do: :always
  defp classify(false, globs, _desc) when globs != [], do: :auto_attached
  defp classify(false, [], desc) when is_binary(desc) and desc != "", do: :agent_requested
  defp classify(_, _, _), do: :manual

  defp derive_name(path) do
    path
    |> Path.basename()
    |> String.replace_suffix(".mdc", "")
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

  defp fetch_bool(fm, key, default) do
    case Map.get(fm, key) do
      true -> true
      false -> false
      "true" -> true
      "false" -> false
      _ -> default
    end
  end

  # Cursor stores `globs` as a comma-separated string by convention, but the
  # YAML flow also allows a list. Accept either.
  defp fetch_globs(fm, key) do
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

  # Path.wildcard compares against the filesystem; we need a pure pattern
  # match against a string. Convert glob -> regex and test.
  #
  # Supported glob syntax:
  #   *   matches any run of non-slash characters (does NOT cross /)
  #   **  matches anything including slashes (tail-position)
  #   **/ matches zero or more path segments (including empty)
  #   ?   matches a single non-slash character
  #
  # Not supported (fall through as literal regex-escaped chars):
  #   {a,b,c}  brace alternation
  #   [abc]    character classes
  #   extglob  +(...), @(...), !(...), ?(...)
  #
  # Cursor's own .mdc globs use the same subset in practice, so any rule
  # that works in Cursor will match here.
  defp glob_match?(glob, path) do
    regex = glob_to_regex(glob)
    Regex.match?(regex, path)
  end

  @spec glob_to_regex(String.t()) :: Regex.t()
  defp glob_to_regex(glob) do
    # Strip any leading "./" since paths we test are already project-relative.
    glob =
      glob
      |> String.trim_leading("./")
      |> String.trim_leading("/")

    pattern = translate(glob, "")
    Regex.compile!("^" <> pattern <> "$")
  end

  defp translate("", acc), do: acc

  defp translate("**/" <> rest, acc), do: translate(rest, acc <> "(?:.*/)?")
  defp translate("**", acc), do: acc <> ".*"
  defp translate("*" <> rest, acc), do: translate(rest, acc <> "[^/]*")
  defp translate("?" <> rest, acc), do: translate(rest, acc <> "[^/]")

  defp translate(<<c::utf8, rest::binary>>, acc) do
    translate(rest, acc <> escape_char(<<c::utf8>>))
  end

  defp escape_char(c) when c in [".", "+", "(", ")", "|", "^", "$", "{", "}", "[", "]", "\\"],
    do: "\\" <> c

  defp escape_char(c), do: c
end
