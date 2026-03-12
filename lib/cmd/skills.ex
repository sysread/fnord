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
            about: "Create a new skill in your editor",
            options: [
              project: Cmd.project_arg()
            ]
          ],
          edit: [
            name: "edit",
            about: "Edit an existing skill in your editor",
            options: [
              project: Cmd.project_arg(),
              skill: [
                value_name: "SKILL",
                long: "--skill",
                short: "-s",
                help: "Skill name to edit",
                required: true
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
              ]
            ]
          ],
          enable: [
            name: "enable",
            about: "Enable a skill in settings",
            options: [
              skill: [
                value_name: "SKILL",
                long: "--skill",
                short: "-s",
                help: "Skill name",
                required: true
              ],
              global: [
                long: "--global",
                help: "Apply to global settings (otherwise current project)",
                takes_value: false
              ],
              project: [
                long: "--project",
                value_name: "PROJECT",
                help: "Apply to the named project (overrides selected project)"
              ]
            ]
          ],
          disable: [
            name: "disable",
            about: "Disable a skill in settings",
            options: [
              skill: [
                value_name: "SKILL",
                long: "--skill",
                short: "-s",
                help: "Skill name",
                required: true
              ],
              global: [
                long: "--global",
                help: "Apply to global settings (otherwise current project)",
                takes_value: false
              ],
              project: [
                long: "--project",
                value_name: "PROJECT",
                help: "Apply to the named project (overrides selected project)"
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
    # Read-only: use project from opts without persisting the selection
    current_project =
      case opts do
        %{project: pn} when is_binary(pn) ->
          pn

        _ ->
          case Settings.get_selected_project() do
            {:ok, pn} -> pn
            _ -> nil
          end
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

  # Both `new` and `edit` open a TOML file in the user's editor. After the
  # user saves and exits, the TOML is decoded, validated (structure, model,
  # tools), string fields are trimmed, and the result is written to the user
  # skills dir. The user is then prompted to configure enablement scope.

  defp new_skill(opts) do
    maybe_set_project_from_opts(opts)

    target_dir = skill_write_dir()
    toml = skill_template()

    with {:ok, skill} <- edit_skill_in_editor(toml, toml),
         :ok <- write_skill_toml(target_dir, skill.name, skill) do
      prompt_enablement(skill.name, opts)
      {:ok, "Saved skill #{skill.name} to #{Path.join(target_dir, "#{skill.name}.toml")}"}
    end
  end

  defp edit_skill(opts) do
    maybe_set_project_from_opts(opts)

    target_dir = skill_write_dir()
    name = opts.skill

    # Intentionally using Skills.get/1 (not get_enabled/1) so disabled skills can be edited
    with {:ok, resolved} <- Skills.get(name),
         {:ok, toml} <- Skills.Toml.encode_skill(resolved.effective.skill),
         {:ok, skill} <- edit_skill_in_editor(toml),
         :ok <- write_skill_toml(target_dir, name, skill) do
      prompt_enablement(name, opts)
      {:ok, "Saved skill #{name} to #{Path.join(target_dir, "#{name}.toml")}"}
    end
  end

  # Open TOML in the editor, then decode, validate, and trim the result.
  # Returns {:ok, %Skills.Skill{}} or {:error, reason}.
  defp edit_skill_in_editor(toml, original \\ nil) do
    edited = UI.open_in_editor(toml, extension: ".toml")

    if original != nil && edited == original do
      {:error, "No changes made - skill was not saved"}
    else
      with {:ok, map} <- Fnord.Toml.decode(edited),
           {:ok, skill, _warnings} <- Skills.Skill.from_map(map),
           skill <- trim_skill_strings(skill),
           :ok <- validate_model_and_tools(skill.model, skill.tools) do
        {:ok, skill}
      else
        {:error, reason} -> {:error, format_skill_error(reason)}
      end
    end
  end

  defp format_skill_error({:missing_key, key}),
    do: "Missing required field: #{key}"

  defp format_skill_error({:invalid_value, key, _value}),
    do: "Field '#{key}' cannot be empty"

  defp format_skill_error({:invalid_type, key, expected, _got}),
    do: "Field '#{key}' must be a #{expected}"

  defp format_skill_error({:unknown_model_preset, model}),
    do:
      "Unknown model preset '#{model}'. Valid presets: #{Enum.join(Skills.Runtime.allowed_model_presets(), ", ")}"

  defp format_skill_error({:unknown_tool_tag, tag}),
    do:
      "Unknown tool tag '#{tag}'. Valid tags: #{Enum.join(Skills.Runtime.allowed_toolboxes(), ", ")}"

  defp format_skill_error({:toml_decode_error, msg}),
    do: "Invalid TOML: #{msg}"

  defp format_skill_error(other),
    do: inspect(other)

  # Trim leading/trailing whitespace from all string fields in the skill.
  defp trim_skill_strings(%Skills.Skill{} = skill) do
    %{
      skill
      | name: String.trim(skill.name),
        description: String.trim(skill.description),
        model: String.trim(skill.model),
        system_prompt: String.trim(skill.system_prompt),
        tools: Enum.map(skill.tools, &String.trim/1)
    }
  end

  @valid_name_pattern ~r/^[a-z0-9][a-z0-9_-]*$/

  defp remove_skill(opts) do
    maybe_set_project_from_opts(opts)

    name = opts.skill

    if not Regex.match?(@valid_name_pattern, name) do
      {:error, "Invalid skill name '#{name}'. Names must match [a-z0-9][a-z0-9_-]*."}
    else
      with {:ok, _project, project_dir} <- ensure_project_selected() do
        path = Path.join(project_dir, "#{name}.toml")

        if UI.confirm("Remove skill file #{path}?", false) do
          case File.rm(path) do
            :ok ->
              {:ok, "Removed #{path}"}

            {:error, :enoent} ->
              {:error, "Skill file not found: #{path}"}

            {:error, :eacces} ->
              {:error, "Permission denied: #{path}"}

            {:error, reason} ->
              {:error, "Could not remove #{path}: #{reason}"}
          end
        else
          {:error, "Aborted"}
        end
      else
        {:error, :no_project_selected} -> return_no_project_error()
      end
    end
  end

  defp enable_skill(opts) do
    with {:ok, scope} <- resolve_scope(opts) do
      Settings.Skills.enable(scope, opts.skill)
      {:ok, "Enabled #{opts.skill} in #{scope_label(scope)} scope."}
    end
  end

  defp disable_skill(opts) do
    with {:ok, scope} <- resolve_scope(opts) do
      Settings.Skills.disable(scope, opts.skill)
      {:ok, "Disabled #{opts.skill} in #{scope_label(scope)} scope."}
    end
  end

  # Resolve --global / --project flags into a scope, defaulting to the
  # currently selected project when neither is given.
  defp resolve_scope(opts) do
    cond do
      opts[:global] ->
        {:ok, :global}

      is_binary(opts[:project]) and byte_size(opts[:project]) > 0 ->
        {:ok, {:project, opts[:project]}}

      true ->
        case Settings.get_selected_project() do
          {:ok, _pn} -> {:ok, :project}
          _ -> {:error, "No project selected. Use --global or --project <name>."}
        end
    end
  end

  defp scope_label(:global), do: "global"
  defp scope_label({:project, name}), do: "project: #{name}"
  defp scope_label(:project), do: "project (selected)"

  # ---------------------------------------------------------------------------
  # Skill TOML template
  #
  # Used by `new` to pre-populate the editor with a commented skeleton showing
  # all fields and their allowed values.
  # ---------------------------------------------------------------------------

  defp skill_template do
    models = Skills.Runtime.allowed_model_presets() |> Enum.join(", ")
    tools = Skills.Runtime.allowed_toolboxes() |> Enum.join(", ")

    """
    # Skill definition
    #
    # Required fields: name, description, model, tools, system_prompt
    # Optional fields: [response_format] table

    # A unique identifier for this skill (used in CLI commands and settings).
    name = "my-skill"

    # Shown to fnord's coordinator when deciding whether to use this skill.
    # Include caller-facing instructions here: what input to provide, what
    # scope or context the agent expects, etc.
    description = "A short description of what this skill does"

    # Model presets: #{models}
    model = "balanced"

    # Tool tags (pick one or more): #{tools}
    tools = ["basic"]

    # The system prompt sent to the model when this skill is invoked.
    # This is the agent's private instructions - the coordinator does not see it.
    # Use triple-quoted strings for multi-line prompts.
    system_prompt = \"\"\"
    You are a helpful assistant.
    \"\"\"
    """
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
        global? = Enum.member?(selections, "(global)")

        Enum.each(selections, fn
          "(skip)" ->
            :ok

          "(global)" ->
            Settings.Skills.enable(:global, name)

          project ->
            # Skip per-project enablement if global was also selected
            unless global? do
              Settings.Skills.enable({:project, project}, name)
            end
        end)

      _ ->
        :ok
    end
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

  # Returns the project skills dir when a project is selected, otherwise the
  # user-global skills dir. Ensures new/edit write to the same location that
  # remove operates on.
  defp skill_write_dir do
    case Skills.project_skills_dir() do
      {:ok, dir} -> dir
      _ -> Skills.user_skills_dir()
    end
  end

  defp return_no_project_error(), do: {:error, "No project selected. Pass --project <name>."}
end
