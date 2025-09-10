defmodule Settings.WorktreeOverrideTest do
  use ExUnit.Case, async: true

  setup do
    Settings.set_project_root_override(nil)
    on_exit(fn -> Settings.set_project_root_override(nil) end)
    :ok
  end

  alias Settings
  alias Briefly

  test "get/set project_root_override" do
    # Default override is nil
    assert Settings.get_project_root_override() == nil

    # Setting a new override path
    {:ok, tmp} = Briefly.create(directory: true)
    assert Settings.set_project_root_override(tmp) == :ok
    assert Settings.get_project_root_override() == tmp

    # Clearing the override
    assert Settings.set_project_root_override(nil) == :ok
    assert Settings.get_project_root_override() == nil
  end
end
