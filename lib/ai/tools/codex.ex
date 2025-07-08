defmodule AI.Tools.Codex do
  @min_version "0.3.0"

  @behaviour AI.Tools

  @impl AI.Tools
  def is_available?() do
    cond do
      !codex_installed?() ->
        Once.warn("""
        Codex CLI not installed.
        Editing tools are disabled.
        """)

        false

      !has_min_version?() ->
        Once.warn("""
        Codex CLI version is too old.
        Minimum required version is #{@min_version}.
        Editing tools are disabled.
        """)

        false

      true ->
        true
    end
  end

  defp codex_installed? do
    "codex"
    |> System.find_executable()
    |> is_nil()
    |> Kernel.not()
  end

  # outputs: `codex-cli 0.3.0`
  defp has_min_version? do
    case System.cmd("codex", ["--version"]) do
      {output, 0} ->
        output
        |> String.trim()
        |> String.split(" ")
        |> case do
          [_, version] -> Version.compare(version, @min_version) != :lt
          _ -> false
        end

      _ ->
        false
    end
  end

  @impl AI.Tools
  def ui_note_on_request(%{"steps" => steps}) do
    steps =
      steps
      |> Enum.map(fn %{"file" => file, "change" => change} ->
        "- #{file}: #{change}"
      end)
      |> Enum.join("\n")

    {"Implementing change plan", steps}
  end

  @impl AI.Tools
  def ui_note_on_result(%{"steps" => steps}, result) do
    steps =
      steps
      |> Enum.map(fn %{"file" => file, "change" => change} ->
        "- #{file}: #{change}"
      end)
      |> Enum.join("\n")

    {"Changes implemented",
     """
     # Steps
     #{steps}

     # Result
     #{result}
     """}
  end

  @impl AI.Tools
  def read_args(args), do: {:ok, args}

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "codex",
        description: """
        Assign a coding task to an AI agent (OpenAI's codex tool).
        The agent can write code in multiple languages, run tests, as well as edit and create files.
        YOU **MUST** MANUALLY DOUBLE-CHECK THE AGENT'S WORK YOURSELF BY READING IT.
        Treat this tool like a junior dev that requires careful guidance and review.
        YOU are the guard rails.
        """,
        parameters: %{
          type: "object",
          required: ["steps"],
          properties: %{
            steps: %{
              type: "array",
              description: """
              A list of steps to be executed by the AI agent.
              Each step should be a small, self-contained change to a single file.
              The AI will execute these steps in order, so ensure they are logically sequenced.
              Each step should be a single, small change in a single file.
              Use this to break down complex tasks into manageable parts.
              """,
              items: %{
                type: "object",
                required: ["file", "change"],
                properties: %{
                  file: %{
                    type: "string",
                    description: """
                    The path to the file to be modified.
                    This should be relative to the project root.
                    Ensure the file exists in the project.
                    """
                  },
                  change: %{
                    type: "string",
                    description: """
                    A concise description of the small, discrete change to be made in the specified file.
                    NEVER use open-ended terms like "refactor" or "improve" without specifying EXACTLY what you want to change.
                    This should be a clear, concise instruction for the AI agent.
                    """
                  }
                }
              }
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(%{"steps" => steps}) do
    ensure_profile_exists!()

    with {:ok, msg} <- perform_steps(steps) do
      step_list =
        steps
        |> Enum.map(fn %{"file" => file, "change" => change} ->
          "- #{file}: #{change}"
        end)
        |> Enum.join("\n")

      {:ok,
       """
       Codex completed execution of the requested steps:
       #{step_list}
       -----
       #{msg}
       -----
       **IMPORTANT**
       Read the updated file(s) carefully!
       Codex tends to take the easiest route, without considering the whole.
       Half the time, it doesn't even DO the work you asked it to.
       There are VERY LIKELY to be problems with its implementation.
       YOU are responsible for identifying them and correcting them.
       """}
    end
  end

  defp perform_steps([]) do
    {:ok, "All steps completed successfully."}
  end

  defp perform_steps([%{"file" => file, "change" => change} | remaining]) do
    with {:ok, output} <- perform_step(file, change) do
      UI.info("Step completed", """
      File:   #{file}
      Change: #{change}
      -----
      #{output}
      """)

      perform_steps(remaining)
    else
      {:error, output} ->
        UI.error("Step failed", """
        File:   #{file}
        Change: #{change}
        -----
        #{output}
        """)

        {:error, output}
    end
  end

  defp perform_step(file, change) do
    with {:ok, project} <- Store.get_project() do
      System.cmd("codex", [
        "exec",
        "--profile",
        "fnord",
        "--cd",
        project.source_root,
        "--sandbox",
        "workspace-write",
        "--ask-for-approval",
        "never",
        "--skip-git-repo-check",
        """
        File: #{file}
        Change: #{change}
        """
      ])
      |> case do
        {output, 0} -> {:ok, output}
        {error_output, _} -> {:error, error_output}
      end
    end
  end

  defp ensure_profile_exists! do
    # Ensure config dir exists
    config_path = Path.join(System.user_home!(), ".codex")
    File.mkdir_p!(config_path)

    # Ensure config file exists
    config_file = Path.join(config_path, "config.toml")
    File.touch!(config_file)

    config = File.read!(config_file)

    if !String.contains?(config, "[profiles.fnord]") do
      UI.info("Adding fnord profile to codex config")

      File.write(config_file, """
      #{config}

      [profiles.fnord]
      model = "gpt-4.1"
      disable_response_storage = true
      """)
    end
  end
end
