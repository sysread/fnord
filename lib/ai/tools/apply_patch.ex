defmodule AI.Tools.ApplyPatch do
  @moduledoc """
  Note: The current crop of LLMs appear to be extremely overfitted to a tool
  called "apply_patch" for making code changes. This module is me giving up on
  trying to prevent them from using the shell tool to call a non-existent
  apply_patch command and instead trying rolling with it.
  """

  # ----------------------------------------------------------------------------
  # Behaviour Implementation
  # ----------------------------------------------------------------------------
  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: false

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def read_args(args), do: {:ok, args}

  @impl AI.Tools
  def ui_note_on_request(%{"patch" => patch}), do: {"Applying patch", patch}

  @impl AI.Tools
  def ui_note_on_result(_args, result), do: {"Patch applied", result}

  @impl AI.Tools
  def spec do
    %{
      type: "function",
      function: %{
        name: "apply_patch",
        description: """
        Apply a unified or git-style diff to the workspace.
        Provide the full diff text in `patch`.
        """,
        parameters: %{
          type: "object",
          additionalProperties: false,
          required: ["patch"],
          properties: %{
            "patch" => %{
              type: "string",
              description:
                "Unified or git diff text (e.g., lines with `diff --git`, `---`, `+++`, `@@`, or *** Begin Patch/End Patch)."
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(args) do
    with {:ok, patch} <- AI.Tools.get_arg(args, "patch"),
         {:ok, patch} <- normalize(patch),
         :ok <- looks_like_diff(patch),
         :ok <- within_size_limits(patch),
         {:ok, paths} <- extract_paths(patch),
         :ok <- paths_safe(paths),
         {:ok, method_args} <- dry_run(File.cwd!(), patch),
         :ok <- do_apply(File.cwd!(), patch, method_args) do
      {:ok, method_args}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # ----------------------------------------------------------------------------
  # Globals
  # ----------------------------------------------------------------------------
  @max_bytes 512_000
  @max_files 100

  @diff_header ~r/^(?:diff --git |\-\-\- |\+\+\+ |@@ |\*\*\* Begin Patch)/m
  @path_lines ~r/^(?:---|\+\+\+)\s+(?:(?:a|b)\/)?(.+)$/
  @devnull "/dev/null"

  # ----------------------------------------------------------------------------
  # Normalization and validation
  # ----------------------------------------------------------------------------

  defp normalize(patch) do
    patch =
      patch
      |> String.replace("\r\n", "\n")
      |> String.replace("\r", "\n")
      |> String.trim_trailing(<<0>>)

    {:ok, patch}
  rescue
    _ -> {:error, "invalid UTF-8"}
  end

  defp looks_like_diff(patch) do
    if Regex.match?(@diff_header, patch), do: :ok, else: {:error, "not a unified/git diff"}
  end

  defp within_size_limits(patch) do
    if byte_size(patch) > @max_bytes, do: {:error, "patch too large"}, else: :ok
  end

  defp extract_paths(patch) do
    paths =
      Regex.scan(@path_lines, patch, return: :index)
      |> Enum.map(fn [{_start, _len}, {pstart, plen}] ->
        binary_part(patch, pstart, plen) |> String.trim()
      end)
      |> Enum.reject(&(&1 == "" or &1 == @devnull))
      |> Enum.uniq()

    if length(paths) > @max_files, do: {:error, "too many files referenced"}, else: {:ok, paths}
  end

  defp paths_safe(paths) do
    unsafe? =
      Enum.any?(paths, fn p ->
        Path.type(p) == :absolute or
          Enum.member?(Path.split(p), "..") or
          String.contains?(p, ["\0", "\n"]) or
          String.ends_with?(p, "/")
      end)

    if unsafe?, do: {:error, "unsafe paths in patch"}, else: :ok
  end

  # ----------------------------------------------------------------------------
  # Dry-run and apply
  # ----------------------------------------------------------------------------

  defp dry_run(root, patch) do
    {:ok, tmp} = Briefly.create()
    :ok = File.write(tmp, patch)
    in_git? = git_repo?(root)

    case in_git? && try_git_check(root, tmp) do
      {:ok, args} ->
        File.rm(tmp)
        {:ok, %{method: :git, args: args}}

      _ ->
        case try_patch_check(root, tmp) do
          {:ok, args} ->
            File.rm(tmp)
            {:ok, %{method: :patch, args: args}}

          {:error, reason} ->
            File.rm(tmp)
            {:error, reason}
        end
    end
  end

  defp do_apply(root, patch, %{method: :git, args: args}) do
    {:ok, tmp} = Briefly.create()
    :ok = File.write(tmp, patch)
    {_, code} = System.cmd("git", ["apply" | args] ++ [tmp], cd: root, stderr_to_stdout: true)
    File.rm(tmp)
    if code == 0, do: :ok, else: {:error, "git apply failed"}
  end

  defp do_apply(root, patch, %{method: :patch, args: args}) do
    {:ok, tmp} = Briefly.create()
    :ok = File.write(tmp, patch)

    {_, code} =
      System.cmd("patch", args ++ ["-r", "-", "-i", tmp], cd: root, stderr_to_stdout: true)

    File.rm(tmp)
    if code == 0, do: :ok, else: {:error, "patch failed"}
  end

  # ----------------------------------------------------------------------------
  # Git and patch helpers
  # ----------------------------------------------------------------------------

  defp git_repo?(root) do
    {_, code} =
      System.cmd("git", ["rev-parse", "--is-inside-work-tree"], cd: root, stderr_to_stdout: true)

    code == 0
  end

  defp try_git_check(root, tmpfile) do
    for args <- [[], ["-p0"], ["-p1"]], reduce: {:error, "git apply --check failed"} do
      _acc ->
        {_, code} =
          System.cmd("git", ["apply", "--check" | args] ++ [tmpfile],
            cd: root,
            stderr_to_stdout: true
          )

        if code == 0, do: {:ok, args}, else: {:error, "git apply --check failed"}
    end
    |> case do
      {:ok, _} = ok -> ok
      _ -> {:error, "git apply --check failed"}
    end
  end

  defp try_patch_check(root, tmpfile) do
    for args <- [["--dry-run", "-p0"], ["--dry-run", "-p1"]],
        reduce: {:error, "patch --dry-run failed"} do
      _acc ->
        {_, code} =
          System.cmd("patch", args ++ ["-r", "-", "-i", tmpfile],
            cd: root,
            stderr_to_stdout: true
          )

        if code == 0, do: {:ok, tl(args)}, else: {:error, "patch --dry-run failed"}
    end
    |> case do
      {:ok, _} = ok -> ok
      _ -> {:error, "patch --dry-run failed"}
    end
  end
end
