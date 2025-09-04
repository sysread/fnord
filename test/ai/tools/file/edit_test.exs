defmodule AI.Tools.File.EditTest do
  use Fnord.TestCase, async: false

  alias AI.Tools.File.Edit

  setup do
    project = mock_project("edit-test")
    {:ok, project: project}
  end

  setup do
    :meck.new(AI.Agent.Code.Patcher, [:no_link, :non_strict, :passthrough])
    on_exit(fn -> :meck.unload(AI.Agent.Code.Patcher) end)
    :ok
  end

  setup do
    Settings.set_edit_mode(true)
    Settings.set_auto_approve(true)

    on_exit(fn ->
      Settings.set_edit_mode(false)
      Settings.set_auto_approve(false)
    end)
  end

  test "call/1", %{project: project} do
    file =
      mock_source_file(project, "example.txt", """
      This is an example file.
      It contains some text that we will edit.
      How now, brown cow?
      """)

    :meck.expect(AI.Agent.Code.Patcher, :get_response, fn args ->
      assert args[:file] == file

      assert args[:changes] == [
               ~s{Replace the word "cow" with "bureaucrat" in the final sentence.}
             ]

      {:ok,
       """
       This is an example file.
       It contains some text that we will edit.
       How now, brown bureaucrat?
       """}
    end)

    assert {:ok, result} =
             Edit.call(%{
               "file" => file,
               "changes" => [
                 %{
                   "change" => """
                   Replace the word "cow" with "bureaucrat" in the final sentence.
                   """
                 }
               ]
             })

    assert result.diff =~ "-How now, brown cow?"
    assert result.diff =~ "+How now, brown bureaucrat?"
    assert result.file == file
    assert result.backup_file == file <> ".0.0.bak"
    assert File.exists?(result.backup_file)

    assert :meck.num_calls(AI.Agent.Code.Patcher, :get_response, :_) == 1
  end

  describe "create_if_missing" do
    test "file is created and patch applied", %{project: project} do
      path = Path.join(project.source_root, "newdir/foo.txt")
      refute File.exists?(path)

      :meck.expect(AI.Agent.Code.Patcher, :get_response, fn args ->
        assert args[:file] == path
        {:ok, "Line One\n"}
      end)

      {:ok, res} =
        Edit.call(%{
          "file" => path,
          "create_if_missing" => true,
          "changes" => [%{"change" => "Add first line"}]
        })

      assert File.exists?(path)
      # Diff headers use labels "ORIGINAL" and "MODIFIED" for new files
      assert res.diff =~ "--- ORIGINAL"
      assert res.diff =~ "+Line One"
      assert res.backup_file == ""
    end

    test "fails when missing and create_if_missing false", %{project: project} do
      path = Path.join(project.source_root, "nope.txt")

      assert {:error, msg} =
               Edit.call(%{"file" => path, "changes" => [%{"change" => "X"}]})

      assert msg =~ "File does not exist"
    end
  end
end
