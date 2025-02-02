defmodule Shell.Completion do
  @moduledoc """
  Public API for generating shell completion scripts.

  This module defines the DSL types and provides a single function to
  generate a completion script for a given shell type. Currently only
  Bash is supported.
  """

  @typedoc "A source for completions: static choices, command output, files, directories, or a custom function (not supported)."
  @type completion_source ::
          {:choices, [String.t()]}
          | {:command, String.t()}
          | :files
          | :directories
          | (String.t() -> [String.t()])

  @typedoc "Specification for an argument."
  @type argument_spec :: %{
          required(:name) => String.t(),
          required(:from) => completion_source
        }

  @typedoc "Specification for an option."
  @type option_spec :: %{
          required(:name) => String.t(),
          optional(:from) => completion_source,
          optional(:takes_argument) => boolean()
        }

  @typedoc "Specification for a subcommand."
  @type subcommand_spec :: %{
          required(:name) => String.t(),
          optional(:description) => String.t(),
          optional(:arguments) => [argument_spec()],
          optional(:options) => [option_spec()],
          optional(:subcommands) => [subcommand_spec()]
        }

  @typedoc "Specification for a top-level command."
  @type command_spec :: %{
          required(:name) => String.t(),
          optional(:description) => String.t(),
          optional(:subcommands) => [subcommand_spec()],
          optional(:arguments) => [argument_spec()],
          optional(:options) => [option_spec()]
        }

  @doc """
  Generates a shell completion script for the given spec.

  ## Options

    * `:shell` - The type of shell to generate completions for (currently only `:bash` is supported).

  ## Example

      Shell.Completion.generate(spec, shell: :bash)
  """
  @spec generate(command_spec(), keyword()) :: String.t()
  def generate(spec, shell: shell_type) do
    case shell_type do
      :bash ->
        Shell.BashCompletion.generate_bash_script(spec)

      other ->
        raise ArgumentError, "Unsupported shell type: #{inspect(other)}"
    end
  end
end
