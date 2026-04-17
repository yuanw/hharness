module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (newTVarIO, readTVarIO)
import Data.Aeson (toJSON)
import Data.IORef
import Data.Int (Int64)
import Data.Text (Text)
import Test.Hspec

import HHAgent

-- ─── Helpers ──────────────────────────────────────────────────────────────

-- | A mock StreamFn that returns a canned AssistantMessage with no tool calls.
mockStreamFn :: Text -> StreamFn
mockStreamFn responseText _model _ctx _opts = do
  es <- newEventStream
  let finalPartial =
        PartialAssistantMessage
          { pamBlocks = [ABText responseText]
          , pamStopReason = StopEndTurn
          , pamErrorMsg = Nothing
          , pamTimestamp = 0
          }
  -- Simulate: start event, text delta, done event
  pushEvent es (EvStart (finalPartial {pamBlocks = []}))
  pushEvent es (EvTextDelta responseText finalPartial)
  pushEvent es (EvDone finalPartial)
  endStream es finalPartial
  pure es

testModel :: Model
testModel = Model "test-model" "test" 4096

-- ─── Tests ────────────────────────────────────────────────────────────────

main :: IO ()
main = hspec $ do
  describe "agentLoop (low-level)" $ do
    it "emits agent_start and agent_end" $ do
      events <- newIORef []
      let ctx = AgentContext "test" [] []
          cfg =
            AgentLoopConfig
              { alcModel = testModel
              , alcStreamOptions = defaultStreamOptions
              , alcConvertToLlm = pure
              , alcTransformContext = Nothing
              , alcGetApiKey = Nothing
              , alcGetSteeringMessages = Nothing
              , alcGetFollowUpMessages = Nothing
              , alcToolExecution = Sequential
              , alcBeforeToolCall = Nothing
              , alcAfterToolCall = Nothing
              }
          sink ev = modifyIORef' events (<> [evType ev])
      _ <- runAgentLoop [] ctx cfg (mockStreamFn "hello") Nothing sink
      recorded <- readIORef events
      head recorded `shouldBe` "agent_start"
      last recorded `shouldBe` "agent_end"

  describe "Agent (high-level)" $ do
    it "becomes idle after promptText" $ do
      let opts = defaultAgentOptions testModel (mockStreamFn "world")
      agent <- newAgent opts
      promptText agent "ping"
      -- Poll briefly; in a real test use waitForIdle
      threadDelay 50000 -- 50 ms
      snap <- getState agent
      snapIsStreaming snap `shouldBe` False

    it "records new messages after a run" $ do
      let opts = defaultAgentOptions testModel (mockStreamFn "response")
      agent <- newAgent opts
      promptText agent "question"
      waitForIdle agent
      snap <- getState agent
      length (snapMessages snap) `shouldSatisfy` (>= 1)

-- | Extract a short type tag from an event for easy comparison.
evType :: AgentEvent -> String
evType EvAgentStart {} = "agent_start"
evType EvAgentEnd {} = "agent_end"
evType EvTurnStart = "turn_start"
evType EvTurnEnd {} = "turn_end"
evType EvMessageStart {} = "message_start"
evType EvMessageUpdate {} = "message_update"
evType EvMessageEnd {} = "message_end"
evType EvToolExecStart {} = "tool_exec_start"
evType EvToolExecUpdate {} = "tool_exec_update"
evType EvToolExecEnd {} = "tool_exec_end"
