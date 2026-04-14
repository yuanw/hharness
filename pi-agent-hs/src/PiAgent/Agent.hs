{- | Stateful Agent wrapper.

Haskell equivalent of @agent.ts@.
All mutable fields live in a single 'TVar'; subscriber removal uses a
monotonic integer key so functions don't need an 'Eq' instance.
-}
module PiAgent.Agent (
  -- * Construction
  AgentOptions (..),
  defaultAgentOptions,
  newAgent,

  -- * The Agent type
  Agent,

  -- * State access
  getState,
  AgentSnapshot (..),

  -- * Subscribing to events
  subscribe,

  -- * Queuing messages
  steer,
  followUp,
  clearAllQueues,

  -- * Running the agent
  prompt,
  promptText,
  continue,

  -- * Control
  abort,
  waitForIdle,
  reset,
) where

import Control.Concurrent (forkIO)
import Control.Concurrent.STM
import Control.Monad (forM_, void, when)
import Data.Function ((&))
import Data.IORef
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Time.Clock.POSIX (getPOSIXTime)

import PiAgent.AgentLoop (StreamFn, runAgentLoop, runAgentLoopContinue)
import PiAgent.Types

-- ─── Configuration ────────────────────────────────────────────────────────

-- | Options used when constructing an 'Agent'.
data AgentOptions = AgentOptions
  { aoSystemPrompt :: Text
  , aoModel :: Model
  , aoThinkingLevel :: ThinkingLevel
  , aoTools :: [AgentTool]
  , aoStreamFn :: StreamFn
  , aoStreamOptions :: StreamOptions
  , aoConvertToLlm :: [AgentMessage] -> IO [Message]
  -- ^ Must not throw; filter out UI-only messages here.
  , aoTransformCtx :: Maybe ([AgentMessage] -> IO [AgentMessage])
  , aoGetApiKey :: Maybe (Text -> IO (Maybe Text))
  , aoBeforeToolCall :: Maybe (BeforeToolCallContext -> IO (Maybe BeforeToolCallResult))
  , aoAfterToolCall :: Maybe (AfterToolCallContext -> IO (Maybe AfterToolCallResult))
  , aoToolExecution :: ToolExecutionMode
  }

-- | Minimal defaults.  Caller must supply 'aoModel' and 'aoStreamFn'.
defaultAgentOptions :: Model -> StreamFn -> AgentOptions
defaultAgentOptions model streamFn =
  AgentOptions
    { aoSystemPrompt = ""
    , aoModel = model
    , aoThinkingLevel = ThinkingOff
    , aoTools = []
    , aoStreamFn = streamFn
    , aoStreamOptions = defaultStreamOptions
    , aoConvertToLlm = pure
    , aoTransformCtx = Nothing
    , aoGetApiKey = Nothing
    , aoBeforeToolCall = Nothing
    , aoAfterToolCall = Nothing
    , aoToolExecution = Parallel
    }

-- ─── Internal state ───────────────────────────────────────────────────────

data InternalState = InternalState
  { _systemPrompt :: Text
  , _model :: Model
  , _thinkingLevel :: ThinkingLevel
  , _tools :: [AgentTool]
  , _messages :: [AgentMessage]
  , _isStreaming :: Bool
  , _streamingMsg :: Maybe AgentMessage
  , _pendingToolCalls :: Set Text
  , _errorMsg :: Maybe Text
  , _steeringQueue :: [AgentMessage]
  , _followUpQueue :: [AgentMessage]
  , _subscribers :: Map Int AgentEventSink
  -- ^ Subscribers keyed by a monotonic ID for O(1) removal.
  , _nextSubId :: Int
  }

mkInitial :: AgentOptions -> InternalState
mkInitial opts =
  InternalState
    { _systemPrompt = aoSystemPrompt opts
    , _model = aoModel opts
    , _thinkingLevel = aoThinkingLevel opts
    , _tools = aoTools opts
    , _messages = []
    , _isStreaming = False
    , _streamingMsg = Nothing
    , _pendingToolCalls = Set.empty
    , _errorMsg = Nothing
    , _steeringQueue = []
    , _followUpQueue = []
    , _subscribers = Map.empty
    , _nextSubId = 0
    }

-- ─── Agent ────────────────────────────────────────────────────────────────

-- | A stateful LLM agent.  Thread-safe.
data Agent = Agent
  { _sv :: TVar InternalState
  , _opts :: AgentOptions
  , _cancelVar :: TVar Bool
  }

-- | Allocate a new agent.
newAgent :: AgentOptions -> IO Agent
newAgent opts =
  Agent
    <$> newTVarIO (mkInitial opts)
    <*> pure opts
    <*> newTVarIO False

-- ─── State snapshot ───────────────────────────────────────────────────────

data AgentSnapshot = AgentSnapshot
  { snapSystemPrompt :: Text
  , snapModel :: Model
  , snapThinkingLevel :: ThinkingLevel
  , snapTools :: [AgentTool]
  , snapMessages :: [AgentMessage]
  , snapIsStreaming :: Bool
  , snapStreamingMessage :: Maybe AgentMessage
  , snapPendingToolCalls :: Set Text
  , snapErrorMessage :: Maybe Text
  }
  deriving (Show)

getState :: Agent -> IO AgentSnapshot
getState agent = do
  s <- readTVarIO (_sv agent)
  pure
    AgentSnapshot
      { snapSystemPrompt = _systemPrompt s
      , snapModel = _model s
      , snapThinkingLevel = _thinkingLevel s
      , snapTools = _tools s
      , snapMessages = _messages s
      , snapIsStreaming = _isStreaming s
      , snapStreamingMessage = _streamingMsg s
      , snapPendingToolCalls = _pendingToolCalls s
      , snapErrorMessage = _errorMsg s
      }

-- ─── Subscriptions ────────────────────────────────────────────────────────

-- | Register an event listener.  Returns an unsubscribe action.
subscribe :: Agent -> AgentEventSink -> IO (IO ())
subscribe agent listener = atomically $ do
  s <- readTVar (_sv agent)
  let subId = _nextSubId s
  writeTVar
    (_sv agent)
    s
      { _subscribers = Map.insert subId listener (_subscribers s)
      , _nextSubId = subId + 1
      }
  pure $
    atomically $
      modifyTVar' (_sv agent) $ \st ->
        st {_subscribers = Map.delete subId (_subscribers st)}

-- ─── Queuing messages ─────────────────────────────────────────────────────

-- | Inject a steering message mid-run (after the current tool calls finish).
steer :: Agent -> AgentMessage -> IO ()
steer agent msg = atomically $
  modifyTVar' (_sv agent) $ \s ->
    s {_steeringQueue = _steeringQueue s <> [msg]}

-- | Enqueue a follow-up message (delivered when the agent would otherwise stop).
followUp :: Agent -> AgentMessage -> IO ()
followUp agent msg = atomically $
  modifyTVar' (_sv agent) $ \s ->
    s {_followUpQueue = _followUpQueue s <> [msg]}

-- | Drain all queued steering and follow-up messages.
clearAllQueues :: Agent -> IO ()
clearAllQueues agent = atomically $
  modifyTVar' (_sv agent) $ \s ->
    s {_steeringQueue = [], _followUpQueue = []}

-- ─── Running ──────────────────────────────────────────────────────────────

{- | Send one or more messages and run the agent loop asynchronously.
Returns immediately; use 'waitForIdle' to block until completion.
-}
prompt :: Agent -> [AgentMessage] -> IO ()
prompt agent msgs = startRun agent $ \ctx cfg cancel sink ->
  runAgentLoop msgs ctx cfg (aoStreamFn (_opts agent)) cancel sink

-- | Convenience wrapper: send a plain text user message.
promptText :: Agent -> Text -> IO ()
promptText agent txt = do
  ts <- now
  prompt agent [UserMessage [mkTextBlock txt] ts]

-- | Continue from the current context without adding a new message.
continue :: Agent -> IO ()
continue agent = startRun agent $ \ctx cfg cancel sink ->
  runAgentLoopContinue ctx cfg (aoStreamFn (_opts agent)) cancel sink

-- ─── Control ──────────────────────────────────────────────────────────────

-- | Signal cancellation.  The current run stops at the next safe checkpoint.
abort :: Agent -> IO ()
abort agent = atomically $ writeTVar (_cancelVar agent) True

-- | Block until the agent is no longer streaming.
waitForIdle :: Agent -> IO ()
waitForIdle agent = atomically $ do
  s <- readTVar (_sv agent)
  when (_isStreaming s) retry

-- | Reset conversation history, queues, and error state without touching config.
reset :: Agent -> IO ()
reset agent = atomically $
  modifyTVar' (_sv agent) $ \s ->
    s
      { _messages = []
      , _isStreaming = False
      , _streamingMsg = Nothing
      , _pendingToolCalls = Set.empty
      , _errorMsg = Nothing
      , _steeringQueue = []
      , _followUpQueue = []
      }

-- ─── Internals ────────────────────────────────────────────────────────────

{- | Generic run harness: snapshot state, fork a background thread, run the
provided loop action, then persist the new messages.
-}
startRun ::
  Agent ->
  (AgentContext -> AgentLoopConfig -> Maybe (IO Bool) -> AgentEventSink -> IO [AgentMessage]) ->
  IO ()
startRun agent runAction = do
  atomically $ do
    writeTVar (_cancelVar agent) False
    modifyTVar' (_sv agent) $ \s ->
      s {_isStreaming = True, _errorMsg = Nothing}
  s <- readTVarIO (_sv agent)
  let ctx = mkContext s
      cfg = mkConfig agent s
      cancel = Just (readTVarIO (_cancelVar agent))
      sink = mkSink agent
  void $ forkIO $ do
    newMsgs <- runAction ctx cfg cancel sink
    atomically $ modifyTVar' (_sv agent) $ \st ->
      st
        { _messages = _messages st <> newMsgs
        , _isStreaming = False
        , _streamingMsg = Nothing
        }

-- | Build the LLM context from a state snapshot.
mkContext :: InternalState -> AgentContext
mkContext s =
  AgentContext
    { acSystemPrompt = _systemPrompt s
    , acMessages = _messages s
    , acTools = _tools s
    }

-- | Build the loop config, wiring steering/follow-up queues into callbacks.
mkConfig :: Agent -> InternalState -> AgentLoopConfig
mkConfig agent s =
  let opts = _opts agent
      sv = _sv agent
   in AgentLoopConfig
        { alcModel = _model s
        , alcStreamOptions =
            (aoStreamOptions opts)
              { soThinking = _thinkingLevel s
              }
        , alcConvertToLlm = aoConvertToLlm opts
        , alcTransformContext = aoTransformCtx opts
        , alcGetApiKey = aoGetApiKey opts
        , alcGetSteeringMessages = Just $ atomically $ do
            st <- readTVar sv
            writeTVar sv st {_steeringQueue = []}
            pure (_steeringQueue st)
        , alcGetFollowUpMessages = Just $ atomically $ do
            st <- readTVar sv
            writeTVar sv st {_followUpQueue = []}
            pure (_followUpQueue st)
        , alcToolExecution = aoToolExecution opts
        , alcBeforeToolCall = aoBeforeToolCall opts
        , alcAfterToolCall = aoAfterToolCall opts
        }

{- | Build an event sink that updates live streaming state and dispatches
to all current subscribers.
-}
mkSink :: Agent -> AgentEventSink
mkSink agent ev = do
  atomically $ modifyTVar' (_sv agent) (applyEvent ev)
  subs <- Map.elems . _subscribers <$> readTVarIO (_sv agent)
  forM_ subs ($ ev)

{- | Update streaming-state fields in response to an event.
Does NOT update _messages (that happens in startRun after the loop exits).
-}
applyEvent :: AgentEvent -> InternalState -> InternalState
applyEvent ev s = case ev of
  EvMessageStart msg@AssistantMessage {} ->
    s {_streamingMsg = Just msg}
  EvMessageUpdate msg _ ->
    s {_streamingMsg = Just msg}
  EvMessageEnd AssistantMessage {} ->
    s {_streamingMsg = Nothing}
  EvToolExecStart tcId _ _ ->
    s {_pendingToolCalls = Set.insert tcId (_pendingToolCalls s)}
  EvToolExecEnd tcId _ _ isErr ->
    s
      { _pendingToolCalls = Set.delete tcId (_pendingToolCalls s)
      , _errorMsg =
          if isErr
            then Just ("Tool failed: " <> tcId)
            else _errorMsg s
      }
  _ -> s

-- ─── Utilities ────────────────────────────────────────────────────────────

now :: IO Int64
now = round . (* 1000) <$> getPOSIXTime
