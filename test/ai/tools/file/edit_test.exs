defmodule AI.Tools.File.EditTest do
  use Fnord.TestCase, async: false

  alias AI.Tools.File.Edit

  setup do
    project = mock_project("edit-test")
    {:ok, project: project}
  end

  setup do
    :meck.new(AI.Agent.Code.Patcher, [:non_strict, :passthrough])
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
end
