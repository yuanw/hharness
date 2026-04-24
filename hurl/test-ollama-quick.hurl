# Quick test of Ollama Anthropic API compatibility
# Usage: hurl --variable model=llama2 test-ollama-quick.hurl


# Simple message creation test
POST http://localhost:11434/v1/messages
anthropic-version: 2023-06-01
Content-Type: application/json
{
  "model": "{{model}}",
  "max_tokens": 100,
  "messages": [
    {
      "role": "user",
      "content": "hi"
    }
  ]
}
HTTP 200
