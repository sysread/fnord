# `tokens`
The files in `./data/tokens` directory are used by `AI.Tokenizer`. They are available from [tiktoken](https://github.com/openai/tiktoken/blob/main/tiktoken_ext/openai_public.py).

## cl100k Base Tokenizer
- [cl100k_base.tiktoken](https://openaipublic.blob.core.windows.net/encodings/cl100k_base.tiktoken)

## o200k Base Tokenizer
- [o200k_base.tiktoken](https://openaipublic.blob.core.windows.net/encodings/o200k_base.tiktoken)

To regenerate tokenizer files, run `data/tokens/build_tokenizer_files.exs`.
Use https://platform.openai.com/tokenizer to generate test data.
