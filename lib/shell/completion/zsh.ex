defmodule Shell.Completion.Zsh do
  @moduledoc """
  Zsh completion script generator. This module should not be used directly.
  Instead, use the `Shell.Completion` module to generate completion scripts.
  """

  alias Shell.Completion, as: API

  @spec generate_zsh_script(API.command_spec()) :: String.t()
  def generate_zsh_script(spec) when is_map(spec) do
    case validate_command_spec(spec) do
      :ok ->
        tables =
          build_tables(
            spec,
            spec.name,
            %{subcommands: %{}, options: %{}, option_args: %{}, argument: %{}}
          )

        generate_zsh_script_from_tables(spec.name, tables)

      error ->
        error
    end
  end

  @spec validate_command_spec(API.command_spec()) :: :ok | {:error, String.t()}
  def validate_command_spec(spec) when is_map(spec) do
    if Map.has_key?(spec, :name), do: :ok, else: {:error, "Command spec must have a :name key"}
  end

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
              completion_source_to_zsh(opt[:from])
            )
          else
            acc
          end
        else
          acc
        end
      end)

    args = Map.get(spec, :arguments, [])

    tables =
      case args do
        [arg | _] ->
          put_in(tables, [:argument, current_path], completion_source_to_zsh(arg[:from]))

        _ ->
          tables
      end

    tables =
      Enum.reduce(Map.get(spec, :subcommands, []), tables, fn sub, acc ->
        acc =
          update_in(acc, [:subcommands, current_path], fn list -> (list || []) ++ [sub[:name]] end)

        new_path = current_path <> ":" <> sub[:name]
        acc = put_in(acc, [:subcommands, new_path], [])
        acc = put_in(acc, [:options, new_path], [])
        acc = put_in(acc, [:argument, new_path], nil)
        build_tables(sub, new_path, acc)
      end)

    tables
  end

  @spec completion_source_to_zsh(API.completion_source()) :: String.t()
  defp completion_source_to_zsh({:choices, choices}) when is_list(choices) do
    "choices:" <> Enum.join(choices, " ")
  end

  defp completion_source_to_zsh({:command, cmd}) when is_binary(cmd) do
    "cmd:" <> cmd
  end

  defp completion_source_to_zsh(:files), do: "files"
  defp completion_source_to_zsh(:directories), do: "directories"

  defp completion_source_to_zsh(fun) when is_function(fun, 1) do
    raise "Custom function completions are not supported in zsh"
  end

  @spec generate_zsh_script_from_tables(String.t(), map()) :: String.t()
  defp generate_zsh_script_from_tables(command_name, tables) do
    header =
      "#compdef #{command_name}\n" <>
        "# Zsh completion script for #{command_name}\n" <>
        "typeset -A _sc_subcommands\n" <>
        "typeset -A _sc_options\n" <>
        "typeset -A _sc_option_args\n" <>
        "typeset -A _sc_argument\n\n"

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
      local cur prev path
      cur=${words[$CURRENT]}
      prev=${words[$CURRENT-1]}
      path=${words[1]}

      local i token
      for (( i=2; i<=$CURRENT; i++ )); do
        token=${words[i]}
        if [[ "$token" == -* ]]; then
          continue
        fi
        local subs=${_sc_subcommands[$path]}
        if [[ -n "$subs" ]]; then
          for sub in $subs; do
            if [[ "$token" == "$sub" ]]; then
              path="$path:$token"
              break
            fi
          done
        fi
      done

      if [[ "$prev" == -* ]]; then
        local key="${path}:${prev}"
        if [[ -n "${_sc_option_args[$key]}" ]]; then
          local spec=${_sc_option_args[$key]}
          if [[ "$spec" == choices:* ]]; then
             local choices=${spec#choices:}
             compadd -- $=choices
             return 0
          elif [[ "$spec" == "files" ]]; then
             _files
             return 0
          elif [[ "$spec" == "directories" ]]; then
             _directories
             return 0
          elif [[ "$spec" == cmd:* ]]; then
             local cmd=${spec#cmd:}
             local choices
             choices=$(eval $cmd)
             compadd -- $=choices
             return 0
          fi
        fi
      fi

      if [[ "$cur" == -* ]]; then
        local opts=${_sc_options[$path]}
        compadd -- $=opts
        return 0
      fi

      local subs=${_sc_subcommands[$path]}
      if [[ -n "$subs" ]]; then
        compadd -- $=subs
        return 0
      fi

      local arg=${_sc_argument[$path]}
      if [[ -n "$arg" ]]; then
        if [[ "$arg" == choices:* ]]; then
           local choices=${arg#choices:}
           compadd -- $=choices
           return 0
        elif [[ "$arg" == "files" ]]; then
           _files
           return 0
        elif [[ "$arg" == "directories" ]]; then
           _directories
           return 0
        elif [[ "$arg" == cmd:* ]]; then
           local cmd=${arg#cmd:}
           local choices
           choices=$(eval $cmd)
           compadd -- $=choices
           return 0
        fi
      fi

      return 0
    }
    compdef _#{command_name}_completion #{command_name}
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
