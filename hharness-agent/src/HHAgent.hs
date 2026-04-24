{- | hharness-agent: Haskell agent loop library.

Typical usage:

@
import HHAgent

myStreamFn :: StreamFn
myStreamFn = ...  -- plug in your LLM provider here

main :: IO ()
main = do
  let model = Model "claude-opus-4-5" "anthropic" 200000
      opts  = (defaultAgentOptions model myStreamFn)
                { aoSystemPrompt = "You are a helpful assistant." }
  agent <- newAgent opts
  _     <- subscribe agent print
  promptText agent "Hello!"
  waitForIdle agent
@
-}
module HHAgent (
  -- * Re-exports: types
  module HHAgent.Types,

  -- * Re-exports: streaming
  module HHAgent.Stream,

  -- * Re-exports: low-level loop
  module HHAgent.AgentLoop,

  -- * Re-exports: high-level agent
  module HHAgent.Agent,

  -- * Anthropic client bridge (Mercury @claude@ package)
  module HHAgent.Claude,
) where

import HHAgent.Agent
import HHAgent.AgentLoop
import HHAgent.Claude
import HHAgent.Stream
import HHAgent.Types
