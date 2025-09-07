defmodule Cmd.Config.Approvals do
  @moduledoc false
  alias Cmd.Config.Utils

  @spec run(map(), list(), list()) :: :ok
  def run(opts, [:approvals], _unknown) do
    cond do
      opts[:global] && opts[:project] ->
        build_list()
        |> Jason.encode!(pretty: true)
        |> IO.puts()

      opts[:global] ->
        build_list(:global)
        |> Jason.encode!(pretty: true)
        |> IO.puts()

      true ->
        case Settings.get_selected_project() do
          {:ok, _proj} ->
            build_list(:project)
            |> Jason.encode!(pretty: true)
            |> IO.puts()

          {:error, _} ->
            UI.error("Project not specified or not found")
        end
    end
  end

  # Unified approve entry
  def run(opts, [:approve], args) do
    cond do
      opts[:global] && opts[:project] ->
        UI.error("Cannot use both --global and --project.")

      is_nil(opts[:kind]) ->
        UI.error("Missing --kind option.")

      true ->
        case Utils.require_key(opts, args, :pattern, "Pattern") do
          {:error, msg} ->
            UI.error(msg)

          {:ok, pattern} ->
            case normalize_pattern(opts[:kind], pattern) do
              {:error, msg} ->
                UI.error(msg)

              {kind, pattern} ->
                # determine scope from --global flag or default to project
                scope = if opts[:global], do: :global, else: :project
                if scope == :project && opts[:project], do: Settings.set_project(opts[:project])
                settings = Settings.new()

                case build_approve(settings, scope, kind, pattern) do
                  {:ok, data} ->
                    data
                    |> Jason.encode!(pretty: true)
                    |> IO.puts()

                  {:error, err} ->
                    UI.error(err)
                end
            end
        end
    end
  end

  # Helpers
  # ----------------------------------------------------------------------------
  defp build_list(:global) do
    Settings.new()
    |> Settings.Approvals.get_approvals(:global)
  end

  defp build_list(:project) do
    Settings.new()
    |> Settings.Approvals.get_approvals(:project)
  end

  defp build_list() do
    global = build_list(:global)
    project = build_list(:project)

    Enum.concat([
      Map.keys(global),
      Map.keys(project)
    ])
    |> Enum.uniq()
    |> Enum.map(fn kind ->
      {
        kind,
        %{
          global: Map.get(global, kind, []),
          project: Map.get(project, kind, [])
        }
      }
    end)
    |> Enum.into(%{})
  end

  # Interpret /pattern/ under --kind shell as full-command regex
  defp normalize_pattern("shell", pat) when is_binary(pat) do
    if String.starts_with?(pat, "/") and String.ends_with?(pat, "/") do
      # Strip leading and trailing slash; use explicit step to avoid negative step warning
      inner = String.slice(pat, 1..-2//1)

      # Return error for empty inner regex
      if inner == "" do
        {:error, "Empty regex is not allowed"}
      else
        {"shell_full", inner}
      end
    else
      {"shell", pat}
    end
  end

  defp normalize_pattern(kind, pat), do: {kind, pat}

  defp build_approve(settings, scope, kind, pattern) do
    if kind == "shell_full" and pattern == "" do
      {:error, "Empty regex is not allowed"}
    else
      # validate that the pattern is a valid regex
      case Regex.compile(pattern, "u") do
        {:error, reason} ->
          # reason is a tuple {message, position}
          msg = elem(reason, 0)
          msg_str = to_string(msg)
          {:error, "Invalid regex: #{msg_str}"}

        {:ok, _regex} ->
          # add the approved prefix and output updated patterns
          new_settings = Settings.Approvals.approve(settings, scope, kind, pattern)
          patterns = Settings.Approvals.get_approvals(new_settings, scope, kind)
          {:ok, %{kind => patterns}}
      end
    end
  end
end
