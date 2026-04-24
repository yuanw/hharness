# Hurl file to test Ollama endpoint for Anthropic API compatibility
# Usage: hurl --variable api_key=your_key --variable model=claude-3-haiku-20240307 test-ollama-anthropic.hurl

# Test 1: List models
GET http://localhost:11434/v1/models
HTTP 200
[Asserts]
jsonpath "$.object" == "list"
jsonpath "$.data" isCollection

# Test 2: Create a message (non-streaming)
POST http://localhost:11434/v1/messages
Authorization: Bearer {{api_key}}
anthropic-version: 2023-06-01
Content-Type: application/json
{
  "model": "{{model}}",
  "max_tokens": 1024,
  "messages": [
    {
      "role": "user",
      "content": "Say 'Hello, World!' and nothing else."
    }
  ]
}
HTTP 200
[Asserts]
jsonpath "$.type" == "message"
jsonpath "$.role" == "assistant"
jsonpath "$.content" isCollection
jsonpath "$.content[0].type" == "text"

# Test 3: Create a message with system prompt
POST http://localhost:11434/v1/messages
Authorization: Bearer {{api_key}}
anthropic-version: 2023-06-01
Content-Type: application/json
{
  "model": "{{model}}",
  "max_tokens": 1024,
  "system": "You are a helpful assistant that answers briefly.",
  "messages": [
    {
      "role": "user",
      "content": "What is 2+2?"
    }
  ]
}
HTTP 200
[Asserts]
jsonpath "$.type" == "message"
jsonpath "$.role" == "assistant"
jsonpath "$.stop_reason" == "end_turn"

# Test 4: Create a streaming message
POST http://localhost:11434/v1/messages
Authorization: Bearer {{api_key}}
anthropic-version: 2023-06-01
Content-Type: application/json
{
  "model": "{{model}}",
  "max_tokens": 1024,
  "stream": true,
  "messages": [
    {
      "role": "user",
      "content": "Count from 1 to 3"
    }
  ]
}
HTTP 200
[Asserts]
header "Content-Type" contains "text/event-stream"

# Test 5: Message with temperature parameter
POST http://localhost:11434/v1/messages
Authorization: Bearer {{api_key}}
anthropic-version: 2023-06-01
Content-Type: application/json
{
  "model": "{{model}}",
  "max_tokens": 100,
  "temperature": 0.5,
  "messages": [
    {
      "role": "user",
      "content": "Hello"
    }
  ]
}
HTTP 200
[Asserts]
jsonpath "$.type" == "message"

# Test 6: Count tokens
POST http://localhost:11434/v1/messages/count_tokens
Authorization: Bearer {{api_key}}
anthropic-version: 2023-06-01
Content-Type: application/json
{
  "model": "{{model}}",
  "messages": [
    {
      "role": "user",
      "content": "Hello, world!"
    }
  ]
}
HTTP 200
[Asserts]
jsonpath "$.input_tokens" isInteger
