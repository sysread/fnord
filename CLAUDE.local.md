# Tests
- Use `Fnord.TestCase` and its helper functions
- Use meck to mock, but that means you need to set `async: false` (not thread-safe)
- Anything that uses `briefly` also seems to not be thread-safe, so use `async: false` there too

# Validation
- `mix format`
- `mix test`
- `mix dialyzer`
- `mix escript.build`
- `make reset-scratch`, then `make escript.build`, then cd into `./scratch`. There is an arbitrary perl project in there that you can use for live testing.
- `./fnord ask -q "testing: ..."`: `testing:` at the start of the question will skip some of the "thinking" and the LLM will just do what you tell it (e.g. "testing: test out the blarg_tool with these parameters: ...")
- `./fnord ask -q "testing: mic check"`: quick test to see if the LLM is responding; good for network tests or changes to `AI.Completion`

# Notes
You may keep independent notes about the project in `./claude/notes.md`.
My advice is not to save ephemeral stuff, but observations about how things fit together and conventions and terminology.

NEVER write to it, but you can get `fnord`'s own notes about itself from `/Users/jeff.ober/.fnord/projects/fnord/notes.md`.
