defmodule MCP.STDIOWrapperTest do
  use Fnord.TestCase, async: false

  test "wrapper suppresses stderr output when command exits 0" do
    wrapper = MCP.STDIOWrapper.script_path!()

    {:ok, tmp} = tmpdir()
    script = Path.join(tmp, "hello.sh")

    File.write!(
      script,
      """
      #!/usr/bin/env bash
      echo 'hello' >&2
      exit 0
      """
    )

    File.chmod!(script, 0o700)
    {output, status} = System.cmd(wrapper, [script], stderr_to_stdout: true)
    assert status == 0
    assert output == ""
  end

  test "wrapper replays captured stderr when command exits non-zero" do
    wrapper = MCP.STDIOWrapper.script_path!()

    {:ok, tmp} = tmpdir()
    failer = Path.join(tmp, "failer")

    File.write!(
      failer,
      """
      #!/usr/bin/env bash
      echo 'kaboom' >&2
      exit 42
      """
    )

    File.chmod!(failer, 0o700)

    {output, status} = System.cmd(wrapper, [failer], stderr_to_stdout: true)

    assert status == 42
    assert output =~ "kaboom"
  end
end
