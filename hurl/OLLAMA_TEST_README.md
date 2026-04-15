# Ollama Anthropic API Compatibility Tests

These Hurl files test whether a local Ollama endpoint is compatible with Anthropic's API.

## Prerequisites

1. Install Hurl: https://hurl.dev/docs/installation.html
2. Have Ollama running locally on port 11434 (default)
3. Have a model pulled in Ollama (e.g., `ollama pull llama2`)

## Usage

### Quick Test
```bash
hurl --variable model=llama2 test-ollama-quick.hurl
```

### Full Test Suite
```bash
hurl --variable model=llama2 --variable api_key=dummy test-ollama-anthropic.hurl
```

Note: Ollama typically doesn't require real API keys, so you can use any placeholder value.

## Test Details

The test suite verifies:
- ✅ Model listing endpoint
- ✅ Basic message creation
- ✅ System prompts support
- ✅ Streaming responses
- ✅ Temperature parameter handling
- ✅ Token counting endpoint

## Expected Ollama Configuration

For Ollama to be fully compatible with Anthropic API, it should have:
- `/v1/models` endpoint
- `/v1/messages` endpoint with support for:
  - `model` parameter
  - `messages` array
  - `max_tokens` parameter
  - `stream` parameter
  - `system` parameter
  - `temperature` parameter
- `/v1/messages/count_tokens` endpoint

## Common Issues

If tests fail:
1. Ensure Ollama is running: `ollama serve`
2. Check if the model exists: `ollama list`
3. Verify port 11434 is accessible
4. Some endpoints may not be implemented in all Ollama versions