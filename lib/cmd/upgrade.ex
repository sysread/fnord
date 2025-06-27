defmodule Cmd.Upgrade do
  @behaviour Cmd

  @impl Cmd
  def requires_project?(), do: false

  @impl Cmd
  def spec do
    [
      upgrade: [
        name: "upgrade",
        about: "Upgrade fnord to the latest version",
        flags: [
          yes: [
            long: "--yes",
            short: "-y",
            help: "Automatically answer 'yes' to all prompts",
            default: false
          ]
        ]
      ]
    ]
  end

  @impl Cmd
  def run(opts, _subcommands, _unknown) do
    Util.get_latest_version()
    |> case do
      {:ok, version} ->
        current = Util.get_running_version()

        if Version.compare(current, version) == :lt do
          IO.puts("Current version: #{current}")
          IO.puts("Latest version: #{version}")

          if UI.confirm("Do you want to upgrade to the latest version of fnord?", opts.yes) do
            System.cmd("mix", ["escript.install", "--force", "github", "sysread/fnord"],
              stderr_to_stdout: true,
              into: IO.stream(:stdio, :line)
            )
          else
            IO.puts("Cancelled")
          end
        else
          IO.puts("You are already on the latest version: #{current}")
          false
        end

      {:error, reason} ->
        IO.puts("Error checking for updates: #{reason}")
        false
    end
  end
end
