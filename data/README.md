# Tokenizer files

The files in this directory are used by `AI.Tokenizer`. They are available from:

- [tiktoken](https://github.com/openai/tiktoken/blob/main/tiktoken_ext/openai_public.py)
- [cl100k_base.tiktoken - text-embedding-3-large](https://openaipublic.blob.core.windows.net/encodings/cl100k_base.tiktoken)
- [o200k_base.tiktoken - gpt-4o | gpt-4o-mini](https://openaipublic.blob.core.windows.net/encodings/o200k_base.tiktoken)

To regenerate tokenizer files, run `data/build_tokenizer_files.exs`.

Use https://platform.openai.com/tokenizer to generate test data.
