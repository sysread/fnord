defmodule Cmd.SkillsGenerateTest do
  use Fnord.TestCase, async: false

  setup do
    Services.Globals.put_env(:fnord, :ui_output, UI.Output.Mock)
    Services.Globals.put_env(:fnord, :test_no_halt, true)
    stub(UI.Output.Mock, :confirm, fn _msg, _default -> true end)

    :meck.new(AI.CompletionAPI, [:no_link, :passthrough, :non_strict])

    on_exit(fn ->
      :meck.unload(AI.CompletionAPI)
      Services.Globals.delete_env(:fnord, :test_no_halt)
    end)

    :ok
  end

  test "--global does not require a project" do
    ref = :erlang.make_ref()
    Process.put(ref, 0)

    :meck.expect(AI.CompletionAPI, :get, fn _model, _msgs, _tools, _rf, _web ->
      case Process.get(ref) do
        0 ->
          Process.put(ref, 1)

          args =
            Jason.encode!(%{
              "scope" => "global",
              "name" => "gen_skill",
              "description" => "x",
              "model" => "balanced",
              "tools" => ["basic"],
              "system_prompt" => "sp",
              "response_format" => nil
            })

          {:ok, :tool,
           [
             %{
               id: "call_1",
               function: %{name: "save_skill", arguments: args}
             }
           ]}

        1 ->
          {:ok, :msg, "ok", 123}
      end
    end)

    {stdout, stderr} =
      capture_all(fn ->
        Cmd.Skills.run(
          %{
            global: true,
            description: "x",
            enable: false,
            project: nil,
            name: nil
          },
          [:generate],
          []
        )
      end)

    assert stdout ==
             "ok\n\nUse `fnord skills enable --skill <SKILL> --global` to enable this skill.\n"

    assert stderr == ""
  end

  test "requires project unless --global" do
    project = mock_project("proj")

    # ResolveProject uses Settings.get_projects, which is backed by the settings file.
    # Ensure there is at least one configured project root, then point the project-root
    # override at a different directory so resolution deterministically fails.
    Settings.set_project_data(Settings.new(), "proj", %{"root" => project.source_root})

    {:ok, other_dir} = tmpdir()
    Services.Globals.delete_env(:fnord, :project)

    File.cd!(other_dir, fn ->
      assert_raise RuntimeError, fn ->
        Cmd.Skills.run(
          %{
            global: false,
            description: "x",
            enable: false,
            project: nil,
            name: nil
          },
          [:generate],
          []
        )
      end
    end)
  end
end
