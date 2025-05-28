#-------------------------------------------------------------------------------
# This is used to verify our generated token counts against the official
# tiktoken library.
#-------------------------------------------------------------------------------
FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1

RUN pip install --no-cache-dir tiktoken

ENTRYPOINT ["python", "-c", "\
import sys, tiktoken; \
text = open(sys.argv[1], encoding='utf-8').read(); \
enc = tiktoken.get_encoding('cl100k_base'); \
tokens = enc.encode(text); \
print(f'{len(tokens)} tokens'); \
"]
