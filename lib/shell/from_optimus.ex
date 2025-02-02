defmodule Shell.FromOptimus do
  @moduledoc """
  Converts an Optimus spec into the `Shell.Completion` DSL format.

  The Optimus spec is assumed to be a keyword list with keys such as:
    - :name (required)
    - :about or :description (for the description)
    - :options and :flags (each a keyword list)
    - :subcommands (a keyword list where each value is a subcommand spec)
    - Optionally :arguments

  The conversion ignores keys like :version, :help, :required, :default, etc.
  It uses the long flag (if available) as the canonical option name.
  For flags, it sets `takes_argument: false`.
  """

  @spec convert(Keyword.t()) :: map()
  def convert(opt_spec) when is_list(opt_spec) do
    convert_spec(opt_spec)
  end

  @doc false
  @spec convert_spec(Keyword.t()) :: map()
  defp convert_spec(opt_spec) when is_list(opt_spec) do
    name = Keyword.fetch!(opt_spec, :name)

    description =
      Keyword.get(opt_spec, :about) ||
        Keyword.get(opt_spec, :description) ||
        ""

    # Convert options (which expect a value) and flags (which are boolean switches)
    options = convert_options(Keyword.get(opt_spec, :options, []))
    flags = convert_flags(Keyword.get(opt_spec, :flags, []))
    all_options = options ++ flags

    # Convert subcommands (assumed to be a keyword list)
    subcommands_kw = Keyword.get(opt_spec, :subcommands, [])

    subcommands =
      case subcommands_kw do
        list when is_list(list) ->
          Enum.map(list, fn {_, sub_spec} ->
            convert_spec(sub_spec)
          end)

        _ ->
          []
      end

    # Convert arguments if provided; otherwise, an empty list.
    arguments_kw = Keyword.get(opt_spec, :arguments, [])

    arguments =
      case arguments_kw do
        list when is_list(list) ->
          Enum.map(list, &convert_argument/1)

        _ ->
          []
      end

    %{
      name: name,
      description: description,
      subcommands: subcommands,
      options: all_options,
      arguments: arguments
    }
  end

  defp convert_spec(opt_spec) when is_map(opt_spec) do
    opt_spec |> Map.to_list() |> convert_spec()
  end

  @spec convert_options(Keyword.t()) :: [map()]
  defp convert_options(options_kw) when is_list(options_kw) do
    Enum.map(options_kw, fn {key, spec} ->
      long = Keyword.get(spec, :long, "--" <> Atom.to_string(key))
      # For our DSL, an option is assumed to take an argument (unless overridden by flags)
      %{name: long}
    end)
  end

  @spec convert_flags(Keyword.t()) :: [map()]
  defp convert_flags(flags_kw) when is_list(flags_kw) do
    Enum.map(flags_kw, fn {key, spec} ->
      long = Keyword.get(spec, :long, "--" <> Atom.to_string(key))
      # For flags, explicitly mark that they do not take an argument.
      %{name: long, takes_argument: false}
    end)
  end

  @spec convert_argument(Keyword.t()) :: map()
  defp convert_argument(arg_spec) when is_list(arg_spec) do
    # For an argument we use the provided :value_name (if any) as the argument name.
    value_name = Keyword.get(arg_spec, :value_name, "arg")
    # If the Optimus spec provided any information on how to complete it (via :from),
    # you could map that here. Otherwise, we'll leave it out.
    from = Keyword.get(arg_spec, :from)
    arg_map = %{name: value_name}
    if from, do: Map.put(arg_map, :from, from), else: arg_map
  end

  defp convert_argument(arg_spec) when is_map(arg_spec) do
    arg_spec |> Map.to_list() |> convert_argument()
  end
end
