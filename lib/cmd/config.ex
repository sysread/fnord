defmodule Cmd.Config do
  @behaviour Cmd

  @impl Cmd
  def requires_project?(), do: false

  @impl Cmd
  def spec do
    [
      config: [
        name: "config",
        about: "Manage configuration settings",
        subcommands: [
          list: [
            name: "list",
            about: "List configuration settings (global or project-specific)",
            options: [
              project: Cmd.project_arg()
            ]
          ],
          set: [
            name: "set",
            about: "Set a configuration directive for a project",
            options: [
              project: Cmd.project_arg(),
              root: [
                value_name: "ROOT",
                long: "--root",
                short: "-r",
                help: "Root directory for the project",
                required: false
              ],
              exclude: [
                value_name: "EXCLUDE",
                long: "--exclude",
                short: "-x",
                help: "Exclude files from the project",
                required: false,
                multiple: true
              ]
            ]
          ],
          approvals: [
            name: "approvals",
            about: "List approval patterns (global or project)",
            options: [
              project: Cmd.project_arg()
            ],
            flags: [
              global: [
                long: "--global",
                short: "-g",
                help: "Use global approvals",
                required: false
              ]
            ]
          ],
          approve: [
            name: "approve",
            about:
              "Add an approval regex under a kind (shell|shell_full) for scope (global|project).",
            args: [
              pattern: [
                value_name: "PATTERN",
                help: "Regex to approve",
                required: true
              ]
            ],
            options: [
              project: Cmd.project_arg(),
              kind: [
                value_name: "KIND",
                long: "--kind",
                short: "-k",
                help:
                  "Approval kind. One of: shell (*prefix* match of command and subcommands), shell_full (*regex* match of full command with args)",
                required: true
              ]
            ],
            flags: [
              global: [
                long: "--global",
                short: "-g",
                help: "Add to global scope. If not set, new patterns are added to project scope.",
                required: false
              ]
            ]
          ],
          mcp: [
            name: "mcp",
            about: "Manage MCP server configuration",
            subcommands: [
              list: [
                name: "list",
                about: "List MCP config (global, project, or effective merge)",
                options: [
                  project: Cmd.project_arg()
                ],
                flags: [
                  global: [
                    long: "--global",
                    short: "-g",
                    help: "Use global scope",
                    required: false
                  ],
                  effective: [
                    long: "--effective",
                    short: "-e",
                    help: "Show merged effective config",
                    required: false
                  ]
                ]
              ],
              add: [
                name: "add",
                about: "Add an MCP server (global or project)",
                args: [
                  name: [value_name: "NAME", help: "Server identifier", required: true]
                ],
                options: [
                  project: Cmd.project_arg(),
                  transport: [
                    value_name: "TRANSPORT",
                    long: "--transport",
                    short: "-t",
                    help: "Transport type (stdio|http|websocket)",
                    default: "stdio"
                  ],
                  command: [
                    value_name: "CMD",
                    long: "--command",
                    short: "-c",
                    help: "Command for stdio transport",
                    required: false
                  ],
                  arg: [
                    value_name: "ARG",
                    long: "--arg",
                    short: "-a",
                    help: "Argument for stdio transport (repeatable)",
                    required: false,
                    multiple: true
                  ],
                  url: [
                    value_name: "URL",
                    long: "--url",
                    short: "-u",
                    help: "Base URL for HTTP/WebSocket transports",
                    required: false
                  ],
                  mcp_path: [
                    value_name: "PATH",
                    long: "--mcp-path",
                    help: "MCP endpoint path for HTTP transport (default: /mcp)",
                    required: false
                  ],
                  header: [
                    value_name: "HEADER",
                    long: "--header",
                    short: "-h",
                    help: "Header for HTTP/WebSocket transports (KEY=VALUE, repeatable)",
                    required: false,
                    multiple: true
                  ],
                  env: [
                    value_name: "ENV",
                    long: "--env",
                    short: "-e",
                    help: "Environment variable for stdio transport (KEY=VALUE, repeatable)",
                    required: false,
                    multiple: true
                  ],
                  timeout_ms: [
                    value_name: "MS",
                    long: "--timeout-ms",
                    short: "-T",
                    help: "Timeout in milliseconds",
                    required: false
                  ],
                  client_id: [
                    value_name: "CLIENT_ID",
                    long: "--client-id",
                    help: "OAuth client ID (optional, will auto-register if not provided)",
                    required: false
                  ],
                  client_secret: [
                    value_name: "CLIENT_SECRET",
                    long: "--client-secret",
                    help: "OAuth client secret (optional)",
                    required: false
                  ],
                  scope: [
                    value_name: "SCOPE",
                    long: "--scope",
                    help: "OAuth scope (repeatable, defaults to mcp:access)",
                    required: false,
                    multiple: true
                  ]
                ],
                flags: [
                  global: [
                    long: "--global",
                    short: "-g",
                    help: "Add server to global configuration",
                    required: false
                  ],
                  oauth: [
                    long: "--oauth",
                    help: "Enable OAuth authentication with auto-discovery",
                    required: false
                  ]
                ]
              ],
              update: [
                name: "update",
                about: "Update an MCP server configuration",
                args: [
                  name: [value_name: "NAME", help: "Server identifier", required: true]
                ],
                options: [
                  project: Cmd.project_arg(),
                  transport: [
                    value_name: "TRANSPORT",
                    long: "--transport",
                    short: "-t",
                    help: "Transport type (stdio|http|websocket)",
                    default: "stdio"
                  ],
                  command: [
                    value_name: "CMD",
                    long: "--command",
                    short: "-c",
                    help: "Command for stdio transport",
                    required: false
                  ],
                  arg: [
                    value_name: "ARG",
                    long: "--arg",
                    short: "-a",
                    help: "Argument for stdio transport (repeatable)",
                    required: false,
                    multiple: true
                  ],
                  url: [
                    value_name: "URL",
                    long: "--url",
                    short: "-u",
                    help: "Base URL for HTTP/WebSocket transports",
                    required: false
                  ],
                  mcp_path: [
                    value_name: "PATH",
                    long: "--mcp-path",
                    help: "MCP endpoint path for HTTP transport (default: /mcp)",
                    required: false
                  ],
                  header: [
                    value_name: "HEADER",
                    long: "--header",
                    short: "-h",
                    help: "Header for HTTP/WebSocket transports (KEY=VALUE, repeatable)",
                    required: false,
                    multiple: true
                  ],
                  env: [
                    value_name: "ENV",
                    long: "--env",
                    short: "-e",
                    help: "Environment variable for stdio transport (KEY=VALUE, repeatable)",
                    required: false,
                    multiple: true
                  ],
                  timeout_ms: [
                    value_name: "MS",
                    long: "--timeout-ms",
                    short: "-T",
                    help: "Timeout in milliseconds",
                    required: false
                  ]
                ],
                flags: [
                  global: [
                    long: "--global",
                    short: "-g",
                    help: "Update server in global configuration",
                    required: false
                  ]
                ]
              ],
              remove: [
                name: "remove",
                about: "Remove an MCP server (global or project)",
                args: [
                  name: [value_name: "NAME", help: "Server identifier", required: true]
                ],
                options: [
                  project: Cmd.project_arg()
                ],
                flags: [
                  global: [
                    long: "--global",
                    short: "-g",
                    help: "Remove server from global configuration",
                    required: false
                  ]
                ]
              ],
              check: [
                name: "check",
                about: "Validate configured MCP servers and show discovered tools",
                options: [
                  project: Cmd.project_arg()
                ],
                flags: [
                  global: [
                    long: "--global",
                    short: "-g",
                    help: "Use global scope",
                    required: false
                  ]
                ]
              ],
              login: [
                name: "login",
                about: "Authenticate to an MCP server using OAuth2 + PKCE",
                args: [
                  server: [value_name: "SERVER", help: "Server identifier", required: true]
                ],
                options: [
                  project: Cmd.project_arg(),
                  timeout: [
                    value_name: "TIMEOUT_MS",
                    long: "--timeout",
                    short: "-t",
                    help: "Timeout in milliseconds for OAuth callback",
                    required: false
                  ]
                ]
              ],
              status: [
                name: "status",
                about: "Show OAuth token status for an MCP server",
                args: [
                  server: [value_name: "SERVER", help: "Server identifier", required: true]
                ],
                options: [
                  project: Cmd.project_arg()
                ]
              ]
            ]
          ]
        ]
      ]
    ]
  end

  @impl Cmd
  def run(_opts, [:list], _unknown) do
    settings = Settings.new()

    global = %{
      "approvals" => Settings.Approvals.get_approvals(settings, :global)
    }

    with {:ok, project} <- Store.get_project() do
      case Settings.get_project_data(settings, project.name) do
        nil ->
          UI.error("Project not found")

        config ->
          global
          |> Map.merge(config)
          |> Jason.encode!(pretty: true)
          |> UI.puts()
      end
    else
      {:error, _} -> UI.error("Project not found")
    end
  end

  def run(opts, [:set], _unknown) do
    case opts[:project] do
      nil ->
        UI.error("Project option is required for set command. Use --project PROJECT_NAME.")

      project_name ->
        Settings.set_project(project_name)

        with {:ok, project} <- Store.get_project() do
          if !Store.Project.exists_in_store?(project) do
            UI.error("""
            Project '#{project.name}' does not exist.
            Please create it with: `fnord index`
            """)
          else
            Store.Project.save_settings(project, opts[:root], opts[:exclude])
            run(opts, [:list], [])
          end
        else
          {:error, _} -> UI.error("Project not found")
        end
    end
  end

  @impl Cmd
  def run(opts, [:approvals], args), do: Cmd.Config.Approvals.run(opts, [:approvals], args)
  def run(opts, [:approve], args), do: Cmd.Config.Approvals.run(opts, [:approve], args)
  def run(opts, [:mcp, :list], args), do: Cmd.Config.MCP.run(opts, [:mcp, :list], args)
  def run(opts, [:mcp, :add], args), do: Cmd.Config.MCP.run(opts, [:mcp, :add], args)
  def run(opts, [:mcp, :update], args), do: Cmd.Config.MCP.run(opts, [:mcp, :update], args)
  def run(opts, [:mcp, :remove], args), do: Cmd.Config.MCP.run(opts, [:mcp, :remove], args)
  def run(opts, [:mcp, :login], args), do: Cmd.Config.MCP.run(opts, [:mcp, :login], args)
  def run(opts, [:mcp, :status], args), do: Cmd.Config.MCP.run(opts, [:mcp, :status], args)
  def run(opts, [:mcp, :check], args), do: Cmd.Config.MCP.run(opts, [:mcp, :check], args)

  def run(opts, [:mcp, :oauth, :list], args),
    do: Cmd.Config.MCP.run(opts, [:mcp, :oauth, :list], args)

  def run(opts, [:mcp, :oauth, :add], args),
    do: Cmd.Config.MCP.run(opts, [:mcp, :oauth, :add], args)

  def run(opts, [:mcp, :oauth, :update], args),
    do: Cmd.Config.MCP.run(opts, [:mcp, :oauth, :update], args)

  def run(opts, [:mcp, :oauth, :remove], args),
    do: Cmd.Config.MCP.run(opts, [:mcp, :oauth, :remove], args)

  def run(_opts, [], _unknown) do
    UI.error("No subcommand specified. Use 'fnord help config' for help.")
  end

  def run(_opts, _subcommands, _unknown) do
    UI.error("Unknown subcommand. Use 'fnord help config' for help.")
  end
end
