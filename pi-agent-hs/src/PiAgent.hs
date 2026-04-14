{- | pi-agent-hs: Haskell port of \@mariozechner\/pi-agent-core.

Typical usage:

@
import PiAgent

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
module PiAgent (
  -- * Re-exports: types
  module PiAgent.Types,

  -- * Re-exports: streaming
  module PiAgent.Stream,

  -- * Re-exports: low-level loop
  module PiAgent.AgentLoop,

  -- * Re-exports: high-level agent
  module PiAgent.Agent,

  -- * Anthropic client bridge (Mercury @claude@ package)
  module PiAgent.Claude,
) where

import PiAgent.Agent
import PiAgent.AgentLoop
import PiAgent.Claude
import PiAgent.Stream
import PiAgent.Types
