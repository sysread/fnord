defmodule AI.Tools.File.EditTest do
  use Fnord.TestCase, async: false

  alias AI.Tools.File.Edit

  setup do
    project = mock_project("edit-test")
    :meck.new(AI.Agent.Code.Patcher, [:non_strict, :passthrough])

    {:ok, project: project}
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

    :meck.expect(Services.Approvals, :confirm, fn args ->
      assert {:ok, "general"} = Keyword.fetch(args, :tag)
      assert {:ok, "edit files"} = Keyword.fetch(args, :subject)
      assert {:ok, message} = Keyword.fetch(args, :message)
      assert {:ok, detail} = Keyword.fetch(args, :detail)

      assert message =~ "Fnord wants to modify #{file}"

      detail = detail |> Owl.Data.untag() |> to_string()
      assert detail =~ "-How now, brown cow?"
      assert detail =~ "+How now, brown bureaucrat?"

      {:ok, :approved}
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
    assert :meck.num_calls(Services.Approvals, :confirm, :_) == 1
  end
end
