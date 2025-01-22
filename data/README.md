# `tokens`

The files in `./data/tokens` directory are used by `AI.Tokenizer`. They are available from:

- [tiktoken](https://github.com/openai/tiktoken/blob/main/tiktoken_ext/openai_public.py)
- [cl100k_base.tiktoken - text-embedding-3-large](https://openaipublic.blob.core.windows.net/encodings/cl100k_base.tiktoken)
- [o200k_base.tiktoken - gpt-4o | gpt-4o-mini](https://openaipublic.blob.core.windows.net/encodings/o200k_base.tiktoken)

To regenerate tokenizer files, run `data/tokens/build_tokenizer_files.exs`.

Use https://platform.openai.com/tokenizer to generate test data.

# `answers.yaml`

This yaml file defines the response templates used by the `AI.Tools.Answers` to generate a response appropriate to the user's query.
They are read in at compile time.

# `strategies.yaml`

This yaml file defines the research strategies stored in `$HOME/.fnord/strategies`.
They are made semantically searchable by `Store.Strategy`.
They are read in at compile time.
