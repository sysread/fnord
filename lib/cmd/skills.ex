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
            about: "Create a new project skill",
            options:
              [
                project: Cmd.project_arg(),
                name: [
                  value_name: "NAME",
                  long: "--name",
                  short: "-n",
                  help: "Skill name",
                  required: false
                ]
              ] ++ skill_field_options() ++ [yes_option()]
          ],
          edit: [
            name: "edit",
            about: "Edit an existing project skill",
            options:
              [
                project: Cmd.project_arg(),
                name: [
                  value_name: "NAME",
                  long: "--name",
                  short: "-n",
                  help: "Skill name to edit",
                  required: true
                ]
              ] ++ skill_field_options() ++ [yes_option()]
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

  # Shared option definitions for skill fields used by both `new` and `edit`.
  defp skill_field_options do
    [
      description: [
        value_name: "DESC",
        long: "--description",
        short: "-d",
        help: "Skill description",
        required: false
      ],
      model: [
        value_name: "MODEL",
        long: "--model",
        short: "-m",
        help: "Model preset (smart/balanced/fast/web/large_context)",
        required: false
      ],
      toolboxes: [
        value_name: "TOOLBOXES",
        long: "--toolboxes",
        short: "-t",
        help: "Tool tags, comma-separated (e.g. basic,web,frobs)",
        required: false
      ],
      system_prompt: [
        value_name: "PROMPT",
        long: "--system-prompt",
        short: "-s",
        help: "System prompt text",
        required: false
      ]
    ]
  end

  defp yes_option do
    {:yes,
     [
       long: "--yes",
       short: "-y",
       help: "Skip confirmation prompts",
       required: false
     ]}
  end

  @impl Cmd
  def run(opts, subcommands, unknown) do
    Services.Once.set(:cli_skills_used, true)

    try do
      with {:ok, msg} <- call_subcommand(opts, subcommands, unknown) do
        msg
        |> UI.Formatter.format_output()
        |> UI.puts()

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

    current_project =
      case Settings.get_selected_project() do
        {:ok, pn} -> pn
        _ -> nil
      end

    with {:ok, skills} <- Skills.list_all() do
      skills
      |> Enum.map(&format_skill(&1, current_project))
      |> Enum.join("\n\n---\n\n")
      |> then(&{:ok, &1})
    end
  end

  defp format_skill(%{name: name, effective: eff, definitions: defs}, current_project) do
    status = format_enabled_scopes(name, current_project)

    tools = Enum.map_join(eff.skill.tools, ", ", &"`#{&1}`")

    defined_in =
      defs
      |> Enum.map(fn %{path: path, source: source} = defn ->
        formatted = format_path(path, source)

        if defn.path == eff.path do
          "- `#{formatted}`"
        else
          "- ~~`#{formatted}`~~"
        end
      end)
      |> Enum.join("\n")

    """
    ### #{name}

    #{eff.skill.description}

    | | |
    |---|---|
    | **Tools** | #{tools} |
    | **Model** | `#{eff.skill.model}` |
    | **Enabled** | #{status} |

    **Defined in:**
    #{defined_in}\
    """
    |> String.trim()
  end

  # Build a scope list showing where a skill is enabled. Global and the
  # current project are bolded for visibility.
  defp format_enabled_scopes(name, current_project) do
    settings = Settings.new()
    projects = Settings.list_projects(settings)

    global_enabled = Enum.member?(Settings.Skills.list(:global), name)

    project_scopes =
      projects
      |> Enum.filter(fn pn -> Enum.member?(Settings.Skills.list({:project, pn}), name) end)

    scopes =
      if(global_enabled, do: [:global], else: []) ++
        Enum.map(project_scopes, fn pn -> {:project, pn} end)

    case scopes do
      [] ->
        "disabled"

      _ ->
        scopes
        |> Enum.map(fn
          :global -> "**global**"
          {:project, pn} when pn == current_project -> "**#{pn}**"
          {:project, pn} -> pn
        end)
        |> Enum.join(" ")
    end
  end

  defp format_path(path, source) do
    case source do
      :user -> String.replace_prefix(path, Settings.get_user_home(), "$HOME")
      :project -> String.replace_prefix(path, Settings.fnord_home(), "~/.fnord")
    end
  end

  # CLI-created skills are user skills and live in ~/fnord/skills/. After saving,
  # the user is prompted to enable the skill for specific projects or globally.
  defp new_skill(opts) do
    maybe_set_project_from_opts(opts)

    user_dir = Skills.user_skills_dir()
    name = prompt_field("Skill name", opts, :name)

    with {:ok, fields} <- prompt_skill_fields(opts),
         :ok <- validate_model_and_tools(fields.model, fields.tools),
         :ok <- confirm_or_abort(opts[:yes], "Save skill #{name} to #{user_dir}?", false),
         :ok <- write_skill_toml(user_dir, name, build_skill(name, fields, nil)) do
      prompt_enablement(name, opts)
      {:ok, "Saved skill #{name} to #{Path.join(user_dir, "#{name}.toml")}"}
    else
      {:abort} -> {:ok, "Aborted"}
      {:error, reason} -> {:error, reason}
    end
  end

  # Editing loads the effective definition and re-prompts for each field,
  # pre-populating with the existing values. Writes back to the user skills dir.
  defp edit_skill(opts) do
    maybe_set_project_from_opts(opts)

    user_dir = Skills.user_skills_dir()
    name = opts.name

    # Intentionally using Skills.get/1 (not get_enabled/1) so disabled skills can be edited
    with {:ok, resolved} <- Skills.get(name) do
      skill = resolved.effective.skill

      with {:ok, fields} <- prompt_skill_fields(opts, skill),
           :ok <- validate_model_and_tools(fields.model, fields.tools),
           :ok <- confirm_or_abort(opts[:yes], "Save skill #{name} to #{user_dir}?", false),
           :ok <- write_skill_toml(user_dir, name, build_skill(name, fields, skill)) do
        {:ok, "Saved skill #{name} to #{Path.join(user_dir, "#{name}.toml")}"}
      else
        {:abort} -> {:ok, "Aborted"}
        {:error, reason} -> {:error, reason}
      end
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

  # ---------------------------------------------------------------------------
  # Shared skill field prompting
  #
  # Both `new` and `edit` collect the same fields. When editing, `existing`
  # provides defaults from the current skill definition. CLI flags override
  # interactive defaults for any field.
  # ---------------------------------------------------------------------------

  defp prompt_skill_fields(opts, existing \\ nil) do
    description =
      prompt_field("Description", opts, :description, skill_default(existing, :description))

    system_prompt =
      prompt_field("System prompt", opts, :system_prompt, skill_default(existing, :system_prompt))

    with {:ok, model} <- choose_model(opts, skill_default(existing, :model)),
         {:ok, tools} <- choose_toolboxes(opts, skill_default(existing, :tools)) do
      {:ok, %{description: description, model: model, tools: tools, system_prompt: system_prompt}}
    end
  end

  defp skill_default(nil, _field), do: nil
  defp skill_default(%Skills.Skill{} = skill, field), do: Map.get(skill, field)

  # Prompt for a string field. If the CLI flag provides a value, use it
  # directly without prompting. Otherwise show an interactive prompt,
  # pre-populated with the existing skill's value (if editing).
  defp prompt_field(label, opts, key, fallback \\ nil) do
    case opt_string(opts, key) do
      nil -> UI.prompt(label, default: fallback)
      value -> value
    end
  end

  defp opt_string(opts, key) do
    case Map.get(opts, key) do
      s when is_binary(s) and s != "" -> s
      _ -> nil
    end
  end

  # Model selection: CLI flag > interactive menu. When editing, the existing
  # model is shown as a default in the menu.
  defp choose_model(opts, existing_default) do
    case opt_string(opts, :model) do
      nil ->
        presets = Skills.Runtime.allowed_model_presets()
        default = if existing_default, do: [existing_default], else: []

        case UI.choose_multi("Select a model preset", presets, min: 1, max: 1, default: default) do
          [model] -> {:ok, model}
          {:error, :no_tty} = err -> err
          other -> {:error, {:invalid_model_selection, other}}
        end

      model ->
        case Skills.Runtime.model_from_string(model) do
          {:ok, _} -> {:ok, model}
          {:error, _} = err -> err
        end
    end
  end

  # Toolbox selection: CLI flag > interactive menu. When editing, the existing
  # tools are shown as defaults in the menu.
  defp choose_toolboxes(opts, existing_default) do
    case opt_string(opts, :toolboxes) do
      nil ->
        options = Skills.Runtime.allowed_toolboxes()
        default = existing_default || []

        label =
          "Select toolboxes (space-separated numbers or ranges, e.g. 1 3-5)"

        case UI.choose_multi(label, options, default: default) do
          selections when is_list(selections) -> {:ok, selections}
          {:error, :no_tty} = err -> err
        end

      toolboxes_str ->
        parsed = parse_csv(toolboxes_str)

        case Skills.Runtime.toolbox_from_tags(parsed) do
          {:ok, _} -> {:ok, parsed}
          {:error, _} = err -> err
        end
    end
  end

  defp build_skill(name, fields, existing_skill) do
    %Skills.Skill{
      name: name,
      description: fields.description,
      model: fields.model,
      tools: fields.tools,
      system_prompt: fields.system_prompt,
      response_format: if(existing_skill, do: existing_skill.response_format, else: nil)
    }
  end

  # Write a skill TOML file to the given directory using atomic writes.
  defp write_skill_toml(dir, name, %Skills.Skill{} = skill) do
    with {:ok, toml} <- Skills.Toml.encode_skill(skill) do
      File.mkdir_p!(dir)
      path = Path.join(dir, "#{name}.toml")
      lock_path = path <> ".lock"

      FileLock.with_lock(lock_path, fn ->
        Settings.write_atomic!(path, toml)
        :ok
      end)
      |> case do
        {:ok, :ok} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # After saving a new skill, prompt the user to enable it for specific
  # projects, globally, or not at all.
  defp prompt_enablement(name, _opts) do
    projects = Settings.list_projects(Settings.new())
    choices = ["(global)" | projects] ++ ["(skip)"]

    label = "Enable #{name} for which scopes? (space-separated numbers or ranges)"

    case UI.choose_multi(label, choices, default: []) do
      selections when is_list(selections) ->
        Enum.each(selections, fn
          "(skip)" ->
            :ok

          "(global)" ->
            Settings.Skills.enable(:global, name)

          project ->
            Settings.set_project(project)
            Settings.Skills.enable(:project, name)
        end)

      _ ->
        :ok
    end
  end

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
  defp confirm_or_abort(nil, message, default), do: confirm_or_abort(false, message, default)
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
