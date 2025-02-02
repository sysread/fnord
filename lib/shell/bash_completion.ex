defmodule Shell.BashCompletion do
  @moduledoc """
  Bash completion script generator. This module should not be used directly.
  Instead, use the `Shell.Completion` module to generate completion scripts.
  """

  alias Shell.Completion, as: API

  @spec generate_bash_script(API.command_spec()) :: String.t()
  def generate_bash_script(spec) when is_map(spec) do
    case validate_command_spec(spec) do
      :ok ->
        tables =
          build_tables(
            spec,
            spec.name,
            %{subcommands: %{}, options: %{}, option_args: %{}, argument: %{}}
          )

        generate_bash_script_from_tables(spec.name, tables)

      error ->
        error
    end
  end

  @spec validate_command_spec(API.command_spec()) :: :ok | {:error, String.t()}
  def validate_command_spec(spec) when is_map(spec) do
    if Map.has_key?(spec, :name) do
      :ok
    else
      {:error, "Command spec must have a :name key"}
    end
  end

  # build_tables/3 traverses the spec and builds four tables:
  #   - subcommands: mapping from "path" to a list of subcommand names.
  #   - options: mapping from "path" to a list of option names.
  #   - option_args: mapping from "path:option" to a completion spec string.
  #   - argument: mapping from "path" to a (positional) argument completion spec.
  @spec build_tables(map(), String.t(), map()) :: map()
  defp build_tables(spec, current_path, tables) do
    tables =
      update_in(tables, [:subcommands, current_path], fn existing ->
        existing || []
      end)

    tables =
      update_in(tables, [:options, current_path], fn existing ->
        existing || []
      end)

    tables = put_in(tables, [:argument, current_path], nil)

    # Process options at this node.
    tables =
      Enum.reduce(Map.get(spec, :options, []), tables, fn opt, acc ->
        acc =
          update_in(acc, [:options, current_path], fn list -> (list || []) ++ [opt[:name]] end)

        if Map.has_key?(opt, :from) do
          takes_argument = Map.get(opt, :takes_argument, true)

          if takes_argument do
            put_in(
              acc,
              [:option_args, "#{current_path}:#{opt[:name]}"],
              completion_source_to_bash(opt[:from])
            )
          else
            acc
          end
        else
          acc
        end
      end)

    # Process argument at this node (we use only the first argument for completion).
    args = Map.get(spec, :arguments, [])

    tables =
      case args do
        [arg | _] ->
          put_in(tables, [:argument, current_path], completion_source_to_bash(arg[:from]))

        _ ->
          tables
      end

    # Process subcommands recursively.
    tables =
      Enum.reduce(Map.get(spec, :subcommands, []), tables, fn sub, acc ->
        acc =
          update_in(acc, [:subcommands, current_path], fn list ->
            (list || []) ++ [sub[:name]]
          end)

        new_path = current_path <> ":" <> sub[:name]
        acc = put_in(acc, [:subcommands, new_path], [])
        acc = put_in(acc, [:options, new_path], [])
        acc = put_in(acc, [:argument, new_path], nil)
        build_tables(sub, new_path, acc)
      end)

    tables
  end

  @spec completion_source_to_bash(API.completion_source()) :: String.t()
  defp completion_source_to_bash({:choices, choices}) when is_list(choices) do
    "choices:" <> Enum.join(choices, " ")
  end

  defp completion_source_to_bash({:command, cmd}) when is_binary(cmd) do
    "cmd:" <> cmd
  end

  defp completion_source_to_bash(:files), do: "files"
  defp completion_source_to_bash(:directories), do: "directories"

  defp completion_source_to_bash(fun) when is_function(fun, 1) do
    raise "Custom function completions are not supported in bash"
  end

  @spec generate_bash_script_from_tables(String.t(), map()) :: String.t()
  defp generate_bash_script_from_tables(command_name, tables) do
    header =
      "#!/usr/bin/env bash\n" <>
        "# Bash completion script for #{command_name}\n" <>
        "declare -A _sc_subcommands\n" <>
        "declare -A _sc_options\n" <>
        "declare -A _sc_option_args\n" <>
        "declare -A _sc_argument\n\n"

    subcommands_lines =
      tables.subcommands
      |> Enum.map(fn {path, subs} ->
        ~s(_sc_subcommands["#{path}"]="#{Enum.join(subs, " ")}")
      end)
      |> Enum.join("\n")

    options_lines =
      tables.options
      |> Enum.map(fn {path, opts} ->
        ~s(_sc_options["#{path}"]="#{Enum.join(opts, " ")}")
      end)
      |> Enum.join("\n")

    option_args_lines =
      tables.option_args
      |> Enum.map(fn {key, spec} ->
        ~s(_sc_option_args["#{key}"]="#{spec}")
      end)
      |> Enum.join("\n")

    argument_lines =
      tables.argument
      |> Enum.filter(fn {_path, arg} -> not is_nil(arg) end)
      |> Enum.map(fn {path, arg} ->
        ~s(_sc_argument["#{path}"]="#{arg}")
      end)
      |> Enum.join("\n")

    function_body = """
    _#{command_name}_completion() {
      local cur prev words cword path
      if type _get_comp_words_by_ref >/dev/null 2>&1; then
          _get_comp_words_by_ref -n : cur prev words cword
      else
          cur="${COMP_WORDS[COMP_CWORD]}"
          prev="${COMP_WORDS[COMP_CWORD-1]}"
          words=("${COMP_WORDS[@]}")
          cword="${COMP_CWORD}"
      fi

      # Determine current path
      path="${words[0]}"
      for ((i=1; i < cword; i++)); do
        token="${words[i]}"
        if [[ "$token" == -* ]]; then
          continue
        fi
        local subs="${_sc_subcommands[$path]}"
        if [[ -n "$subs" ]]; then
          for sub in $subs; do
             if [[ "$token" == "$sub" ]]; then
               path="${path}:$token"
               break
             fi
          done
        fi
      done

      # Check if previous token is an option expecting an argument.
      if [[ "$prev" == -* ]]; then
        local key="${path}:${prev}"
        if [[ -n "${_sc_option_args[$key]}" ]]; then
          local spec="${_sc_option_args[$key]}"
          if [[ "$spec" == choices:* ]]; then
             local choices="${spec#choices:}"
             COMPREPLY=( $(compgen -W "$choices" -- "$cur") )
             return 0
          elif [[ "$spec" == "files" ]]; then
             COMPREPLY=( $(compgen -f -- "$cur") )
             return 0
          elif [[ "$spec" == "directories" ]]; then
             COMPREPLY=( $(compgen -d -- "$cur") )
             return 0
          elif [[ "$spec" == cmd:* ]]; then
             local cmd="${spec#cmd:}"
             local choices
             choices=$(eval "$cmd")
             COMPREPLY=( $(compgen -W "$choices" -- "$cur") )
             return 0
          fi
        fi
      fi

      # If current token starts with '-', complete options.
      if [[ "$cur" == -* ]]; then
        local opts="${_sc_options[$path]}"
        COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
        return 0
      fi

      # Otherwise, complete subcommands if any.
      local subs="${_sc_subcommands[$path]}"
      if [[ -n "$subs" ]]; then
        COMPREPLY=( $(compgen -W "$subs" -- "$cur") )
        return 0
      fi

      # Otherwise, complete argument if defined.
      local arg="${_sc_argument[$path]}"
      if [[ -n "$arg" ]]; then
        if [[ "$arg" == choices:* ]]; then
           local choices="${arg#choices:}"
           COMPREPLY=( $(compgen -W "$choices" -- "$cur") )
           return 0
        elif [[ "$arg" == "files" ]]; then
           COMPREPLY=( $(compgen -f -- "$cur") )
           return 0
        elif [[ "$arg" == "directories" ]]; then
           COMPREPLY=( $(compgen -d -- "$cur") )
           return 0
        elif [[ "$arg" == cmd:* ]]; then
           local cmd="${arg#cmd:}"
           local choices
           choices=$(eval "$cmd")
           COMPREPLY=( $(compgen -W "$choices" -- "$cur") )
           return 0
        fi
      fi

      return 0
    }
    complete -F _#{command_name}_completion #{command_name}
    """

    [
      header,
      subcommands_lines,
      options_lines,
      option_args_lines,
      argument_lines,
      "\n",
      function_body
    ]
    |> Enum.filter(&(&1 != ""))
    |> Enum.join("\n")
  end
end
