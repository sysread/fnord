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
        cmp = Version.compare(current, version)

        confirm =
          case cmp do
            :lt ->
              "Do you want to upgrade to the latest version of fnord?"

            :eq ->
              "You are on the latest version of fnord. Would you like to reinstall?"

            :gt ->
              raise "Current version is greater than the latest version. Versions are really made of wibbly-wobbly, timey-wimey stuff."
          end

        if Version.compare(current, version) != :gt do
          UI.puts("Current version: #{current}")
          UI.puts("Latest version: #{version}")

          if UI.confirm(confirm, opts.yes) do
            System.cmd("mix", ["escript.install", "--force", "github", "sysread/fnord"],
              stderr_to_stdout: true,
              into: IO.stream(:stdio, :line)
            )
          else
            UI.puts("Cancelled")
          end
        else
          UI.puts("You are already on the latest version: #{current}")
          false
        end

      {:error, reason} ->
        UI.puts("Error checking for updates: #{reason}")
        false
    end
  end
end
