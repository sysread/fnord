defmodule Cmd.Skills do
  @moduledoc """
  CLI management for Skills.

  This command family supports:
  - listing skills (including overridden definitions),
  - creating/editing/removing skill TOML files under the project skills directory,
  - enabling/disabling skills via settings at global and project scope.

  Skill definitions are stored as TOML in:
  - user dir: `~/fnord/skills`
  - project dir: `~/.fnord/projects/<project>/skills`

  User definitions override project definitions by name.
  """

  @behaviour Cmd

  @impl Cmd
  def requires_project?(), do: false

  @impl Cmd
  def spec do
    [
      skills: [
        name: "skills",
        about: "Manage skills",
        subcommands: [
          list: [
            name: "list",
            about: "List skills",
            options: [
              project: Cmd.project_arg()
            ]
          ],
          new: [
            name: "new",
            about: "Interactively create a new project skill",
            options: [
              project: Cmd.project_arg(),
              yes: [
                long: "--yes",
                short: "-y",
                help: "Skip confirmation prompts",
                required: false
              ]
            ]
          ],
          edit: [
            name: "edit",
            about: "Interactively edit an existing skill",
            options: [
              project: Cmd.project_arg(),
              skill: [
                value_name: "SKILL",
                long: "--skill",
                short: "-s",
                help: "Skill name",
                required: true
              ],
              yes: [
                long: "--yes",
                short: "-y",
                help: "Skip confirmation prompts",
                required: false
              ]
            ]
          ],
          remove: [
            name: "remove",
            about: "Remove a project skill definition",
            options: [
              project: Cmd.project_arg(),
              skill: [
                value_name: "SKILL",
                long: "--skill",
                short: "-s",
                help: "Skill name",
                required: true
              ],
              yes: [
                long: "--yes",
                short: "-y",
                help: "Skip confirmation prompts",
                required: false
              ]
            ]
          ],
          enable: [
            name: "enable",
            about: "Enable a skill in settings",
            options: [
              project: Cmd.project_arg(),
              skill: [
                value_name: "SKILL",
                long: "--skill",
                short: "-s",
                help: "Skill name",
                required: true
              ],
              scope: [
                value_name: "SCOPE",
                long: "--scope",
                short: "-S",
                help: "Scope: project or global",
                required: true
              ],
              yes: [
                long: "--yes",
                short: "-y",
                help: "Skip confirmation prompts",
                required: false
              ]
            ]
          ],
          disable: [
            name: "disable",
            about: "Disable a skill in settings",
            options: [
              project: Cmd.project_arg(),
              skill: [
                value_name: "SKILL",
                long: "--skill",
                short: "-s",
                help: "Skill name",
                required: true
              ],
              scope: [
                value_name: "SCOPE",
                long: "--scope",
                short: "-S",
                help: "Scope: project or global",
                required: true
              ],
              yes: [
                long: "--yes",
                short: "-y",
                help: "Skip confirmation prompts",
                required: false
              ]
            ]
          ]
        ]
      ]
    ]
  end

  @impl Cmd
  def run(opts, subcommands, unknown) do
    Services.Once.set(:cli_skills_used, true)

    try do
      with {:ok, msg} <- call_subcommand(opts, subcommands, unknown) do
        UI.puts(msg)
        {:ok, msg}
      else
        {:error, reason} ->
          UI.fatal("skills", inspect(reason))
      end
    rescue
      e in RuntimeError ->
        UI.fatal("skills", Exception.message(e))
    end
  end

  defp call_subcommand(opts, [:list], _unknown), do: list(opts)
  defp call_subcommand(opts, [:new], _unknown), do: new_skill(opts)
  defp call_subcommand(opts, [:edit], _unknown), do: edit_skill(opts)
  defp call_subcommand(opts, [:remove], _unknown), do: remove_skill(opts)
  defp call_subcommand(opts, [:enable], _unknown), do: enable_skill(opts)
  defp call_subcommand(opts, [:disable], _unknown), do: disable_skill(opts)
  defp call_subcommand(_opts, _sub, _unknown), do: {:error, :invalid_subcommand}

  defp list(opts) do
    maybe_set_project_from_opts(opts)

    with {:ok, skills} <- Skills.list_all() do
      enabled = Settings.Skills.effective_enabled()

      skills
      |> Enum.map(&format_skill(&1, enabled))
      |> Enum.join("\n\n")
      |> then(&{:ok, &1})
    end
  end

  defp format_skill(%{name: name, effective: eff, definitions: defs}, enabled) do
    enabled_label = if MapSet.member?(enabled, name), do: "enabled", else: "disabled"

    defined_in =
      defs
      |> Enum.map(fn %{path: path, source: source} = defn ->
        line = "- #{format_path(path, source)}"

        if defn.path == eff.path do
          line
        else
          "~#{line}~"
        end
      end)
      |> Enum.join("\n")

    [
      "Name: #{name}",
      "Description: #{eff.skill.description}",
      "Tools: #{Enum.join(eff.skill.tools, ", ")}",
      "Model: #{eff.skill.model}",
      "Status: #{enabled_label}",
      "Defined in:\n#{defined_in}"
    ]
    |> Enum.join("\n")
  end

  defp format_path(path, source) do
    case source do
      :user -> String.replace_prefix(path, Settings.get_user_home(), "$HOME")
      :project -> String.replace_prefix(path, Settings.fnord_home(), "~/.fnord")
    end
  end

  defp new_skill(opts) do
    maybe_set_project_from_opts(opts)

    with {:ok, _project, project_dir} <- ensure_project_selected() do
      name = UI.prompt("Skill name")
      description = UI.prompt("Description")
      model = UI.prompt("Model preset (smart/balanced/fast/web/large_context)")
      tools = UI.prompt("Tool tags (comma-separated)") |> parse_csv()
      system_prompt = UI.prompt("System prompt")

      args = %{
        "name" => name,
        "description" => description,
        "model" => model,
        "tools" => tools,
        "system_prompt" => system_prompt,
        "response_format" => nil
      }

      yes? = Map.get(opts, :yes, false)

      with :ok <- validate_model_and_tools(model, tools),
           :ok <- confirm_or_abort(yes?, "Create skill #{name} in #{project_dir}?", false) do
        AI.Tools.SaveSkill.call(args)
      else
        {:abort} -> {:ok, "Aborted"}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :no_project_selected} ->
        return_no_project_error()
    end
  end

  defp edit_skill(opts) do
    maybe_set_project_from_opts(opts)

    name = opts.skill

    with {:ok, resolved} <- Skills.get(name),
         {:ok, _project, project_dir} <- ensure_project_selected() do
      if resolved.effective.source == :user do
        {:error, {:cannot_edit_user_skill, name}}
      else
        skill = resolved.effective.skill

        description = UI.prompt("Description", default: skill.description)
        model = UI.prompt("Model preset", default: skill.model)

        tools =
          UI.prompt("Tool tags (comma-separated)", default: Enum.join(skill.tools, ","))
          |> parse_csv()

        system_prompt = UI.prompt("System prompt", default: skill.system_prompt)

        args = %{
          "name" => name,
          "description" => description,
          "model" => model,
          "tools" => tools,
          "system_prompt" => system_prompt,
          "response_format" => skill.response_format
        }

        yes? = Map.get(opts, :yes, false)

        if yes? or UI.confirm("Overwrite skill #{name} in #{project_dir}?", false) do
          AI.Tools.SaveSkill.call(args)
        else
          {:ok, "Aborted"}
        end
      end
    else
      {:error, :no_project_selected} -> return_no_project_error()
    end
  end

  defp remove_skill(opts) do
    maybe_set_project_from_opts(opts)

    name = opts.skill

    with {:ok, _project, project_dir} <- ensure_project_selected() do
      path = Path.join(project_dir, "#{name}.toml")

      yes? = Map.get(opts, :yes, false)

      if yes? or UI.confirm("Remove skill file #{path}?", false) do
        case File.rm(path) do
          :ok -> {:ok, "Removed #{path}"}
          {:error, reason} -> {:error, reason}
        end
      else
        {:ok, "Aborted"}
      end
    else
      {:error, :no_project_selected} -> return_no_project_error()
    end
  end

  defp enable_skill(opts) do
    maybe_set_project_from_opts(opts)

    scope = parse_scope(opts.scope)

    yes? = Map.get(opts, :yes, false)

    if yes? or UI.confirm("Enable skill #{opts.skill} in #{opts.scope} scope?", false) do
      Settings.Skills.enable(scope, opts.skill)
      {:ok, "Enabled #{opts.skill} (#{opts.scope})"}
    else
      {:ok, "Aborted"}
    end
  end

  defp disable_skill(opts) do
    maybe_set_project_from_opts(opts)

    scope = parse_scope(opts.scope)

    yes? = Map.get(opts, :yes, false)

    if yes? or UI.confirm("Disable skill #{opts.skill} in #{opts.scope} scope?", false) do
      Settings.Skills.disable(scope, opts.skill)
      {:ok, "Disabled #{opts.skill} (#{opts.scope})"}
    else
      {:ok, "Aborted"}
    end
  end

  defp parse_scope("global"), do: :global
  defp parse_scope("project"), do: :project
  defp parse_scope(other), do: raise("Invalid scope #{inspect(other)}")

  defp parse_csv(str) when is_binary(str) do
    str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp maybe_set_project_from_opts(%{project: nil}), do: :ok

  defp maybe_set_project_from_opts(%{project: project}) when is_binary(project) do
    Settings.set_project(project)
    :ok
  end

  # Validate model and tools
  defp validate_model_and_tools(model, tools) do
    with {:ok, _} <- Skills.Runtime.model_from_string(model),
         {:ok, _} <- Skills.Runtime.toolbox_from_tags(tools) do
      :ok
    end
  end

  # Confirm or abort based on user input and yes flag.
  # If yes? is true, returns :ok immediately.
  # Otherwise prompts and returns :ok or {:abort}.
  defp confirm_or_abort(true, _message, _default), do: :ok

  defp confirm_or_abort(false, message, default) do
    case UI.confirm(message, default) do
      true -> :ok
      false -> {:abort}
    end
  end

  # Ensures that a project has been selected before proceeding.
  # Returns {:ok, project_name, project_dir} if a project is set,
  # or {:error, :no_project_selected} otherwise.
  defp ensure_project_selected do
    case Settings.get_selected_project() do
      {:ok, project} ->
        case Skills.project_skills_dir() do
          {:ok, project_dir} -> {:ok, project, project_dir}
          {:error, reason} -> {:error, reason}
        end

      {:error, _} ->
        {:error, :no_project_selected}
    end
  end

  defp return_no_project_error(), do: {:error, "No project selected. Pass --project <name>."}
end
