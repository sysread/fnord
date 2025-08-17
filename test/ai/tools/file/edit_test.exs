defmodule AI.Tools.File.EditTest do
  use Fnord.TestCase, async: false

  alias AI.Tools.File.Edit

  setup do
    :meck.new(Services.Approvals, [:non_strict, :passthrough])
    :meck.new(AI.Agent.Code.HunkFinder, [:non_strict, :passthrough])
    :meck.new(AI.Agent.Code.PatchMaker, [:non_strict, :passthrough])

    project = mock_project("edit-test")

    {:ok, project: project}
  end

  test "call/1", %{project: project} do
    file =
      mock_source_file(project, "example.txt", """
      This is an example file.
      It contains some text that we will edit.
      How now, brown cow? 
      """)

    criteria = "How now, brown cow?"
    replacement = "How now, brown bureaucrat?"

    :meck.expect(AI.Agent.Code.HunkFinder, :get_response, fn args ->
      assert args.file == file
      assert ^criteria = args.criteria
      assert ^replacement = args.replacement
      Hunk.new(file, 3, 3)
    end)

    :meck.expect(AI.Agent.Code.PatchMaker, :get_response, fn args ->
      assert args.file == file
      assert %Hunk{file: ^file, start_line: 3, end_line: 3} = args.hunk
      assert ^replacement = args.replacement
      {:ok, replacement}
    end)

    :meck.expect(Services.Approvals, :confirm, fn args ->
      assert {:ok, "general"} = Keyword.fetch(args, :tag)
      assert {:ok, "edit files"} = Keyword.fetch(args, :subject)
      assert {:ok, message} = Keyword.fetch(args, :message)
      assert {:ok, detail} = Keyword.fetch(args, :detail)

      assert message =~ "Fnord wants to modify #{file}:3...3"

      detail = detail |> Owl.Data.untag() |> to_string()
      assert detail =~ "-How now, brown cow?"
      assert detail =~ "+How now, brown bureaucrat?"

      {:ok, :approved}
    end)

    assert {:ok, diff} =
             Edit.call(%{
               "file" => file,
               "find" => criteria,
               "replacement" => replacement
             })

    assert diff =~ "-How now, brown cow?"
    assert diff =~ "+How now, brown bureaucrat?"

    assert File.exists?(file <> ".0.0.bak")

    assert :meck.num_calls(AI.Agent.Code.HunkFinder, :get_response, :_) == 1
    assert :meck.num_calls(AI.Agent.Code.PatchMaker, :get_response, :_) == 1
    assert :meck.num_calls(Services.Approvals, :confirm, :_) == 1
  end
end
