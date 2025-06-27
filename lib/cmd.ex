defmodule Cmd do
  @callback spec() :: Keyword.t()

  @callback run(opts :: map, subcommands :: list, unknown :: list) :: any

  @callback requires_project?() :: boolean

  def default_workers, do: 12

  def perform_command(cmd, opts, subcommands, unknown) do
    cmd.run(opts, subcommands, unknown)
  end

  def project_arg do
    [
      value_name: "PROJECT",
      long: "--project",
      short: "-p",
      help: "Project name; CWD is used to identify an indexed project unless specified.",
      required: false
    ]
  end
end
