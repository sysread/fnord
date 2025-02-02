defmodule Shell.Shell.FromOptimusTest do
  use ExUnit.Case

  describe "convert/1" do
    test "converts a spec with global options and subcommands" do
      optimus_spec = [
        name: "fnord",
        description:
          "fnord - an AI powered, conversational interface for your project that learns",
        # Global options provided at top-level
        options: [
          global: [
            value_name: "GLOBAL",
            long: "--global",
            short: "-g",
            help: "Global option"
          ]
        ],
        # Single subcommand "ask" with both options and flags
        subcommands: [
          ask: [
            name: "ask",
            about: "Ask the AI",
            options: [
              project: [
                value_name: "PROJECT",
                long: "--project",
                short: "-p",
                help: "Project name",
                required: true
              ],
              question: [
                value_name: "QUESTION",
                long: "--question",
                short: "-q",
                help: "Ask question",
                required: true
              ],
              workers: [
                value_name: "WORKERS",
                long: "--workers",
                short: "-w",
                help: "Worker count"
              ],
              follow: [
                long: "--follow",
                short: "-f",
                help: "Follow up"
              ]
            ],
            flags: [
              continue: [
                long: "--continue",
                short: "-c",
                help: "Continue conversation"
              ],
              replay: [
                long: "--replay",
                short: "-r",
                help: "Replay conversation"
              ]
            ]
          ]
        ]
      ]

      dsl_spec = Shell.FromOptimus.convert(optimus_spec)

      # Top-level keys should be present.
      assert is_map(dsl_spec)
      assert dsl_spec.name == "fnord"

      assert dsl_spec.description ==
               "fnord - an AI powered, conversational interface for your project that learns"

      # The top-level options come from the :options key.
      expected_global = [%{name: "--global"}]
      assert dsl_spec.options == expected_global

      # Check subcommands: there should be one subcommand ("ask")
      assert is_list(dsl_spec.subcommands)
      assert length(dsl_spec.subcommands) == 1

      ask = hd(dsl_spec.subcommands)
      assert ask.name == "ask"
      # We expect the description to come from the :about key.
      assert ask.description == "Ask the AI"
      # Since no top-level arguments were provided, we expect an empty list.
      assert ask.arguments == []

      # Options from the ask subcommand: convert_options maps each option entry
      expected_ask_options = [
        %{name: "--project"},
        %{name: "--question"},
        %{name: "--workers"},
        %{name: "--follow"},
        # Flags are converted with takes_argument: false.
        %{name: "--continue", takes_argument: false},
        %{name: "--replay", takes_argument: false}
      ]

      assert ask.options == expected_ask_options

      # And ask.subcommands should be an empty list.
      assert ask.subcommands == []
    end

    test "converts a spec with no top-level options" do
      optimus_spec = [
        name: "fnord",
        description: "Test fnord",
        # No global options provided here
        subcommands: [
          ask: [
            name: "ask",
            about: "Ask the AI",
            options: [project: [long: "--project"]],
            flags: []
          ]
        ]
      ]

      dsl_spec = Shell.FromOptimus.convert(optimus_spec)
      # Top-level options should be an empty list.
      assert dsl_spec.options == []
    end

    test "converts subcommand with multiple nested fields" do
      # This test mimics a subcommand that might have both options and flags.
      optimus_spec = [
        name: "fnord",
        description: "Test fnord",
        subcommands: [
          test: [
            name: "test",
            about: "A test subcommand",
            options: [
              alpha: [long: "--alpha"],
              beta: [long: "--beta"]
            ],
            flags: [
              gamma: [long: "--gamma"]
            ]
          ]
        ]
      ]

      dsl_spec = Shell.FromOptimus.convert(optimus_spec)
      [test_cmd] = dsl_spec.subcommands

      expected_options = [
        %{name: "--alpha"},
        %{name: "--beta"},
        %{name: "--gamma", takes_argument: false}
      ]

      assert test_cmd.options == expected_options
    end
  end
end
