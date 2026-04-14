{- | Pure agent loop logic.

Haskell equivalent of @agent-loop.ts@.
State is threaded via 'IORef' rather than mutated on a class; the two-level
loop structure (outer: follow-ups, inner: tool calls + steering) is preserved
exactly from the TypeScript original.
-}
module PiAgent.AgentLoop (
  -- * Stream function type
  StreamFn,

  -- * High-level entry points (return an EventStream)
  agentLoop,
  agentLoopContinue,

  -- * Low-level entry points (take an event sink)
  runAgentLoop,
  runAgentLoopContinue,
) where

import Control.Concurrent.Async (async, wait)
import Control.Exception (SomeException, try)
import Control.Monad (forM, forM_, unless, when)
import Data.Aeson (Value, toJSON)
import Data.IORef
import Data.Int (Int64)
import Data.List (find, foldl')
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (getPOSIXTime)

import PiAgent.Stream (EventStream, endStream, foldStream, newEventStream, pushEvent)
import PiAgent.Types

-- ─── Public type ──────────────────────────────────────────────────────────

{- | A function that calls an LLM and returns a stream of events.

Contract (mirrors the TypeScript):
* Must not throw or return a failed 'IO' action.
* Failures must be encoded as 'EvError' events with 'StopError' / 'StopAborted'.
-}
type StreamFn =
  Model ->
  LLMContext ->
  StreamOptions ->
  IO (EventStream AssistantMessageEvent PartialAssistantMessage)

-- ─── High-level entry points ──────────────────────────────────────────────

{- | Start an agent loop with new prompt messages.
Returns an 'EventStream' whose final result is the list of messages added
during this run (prompts + assistant turns + tool results).
-}
agentLoop ::
  [AgentMessage] ->
  AgentContext ->
  AgentLoopConfig ->
  StreamFn ->
  -- | cancellation check: return 'True' to cancel
  Maybe (IO Bool) ->
  IO (EventStream AgentEvent [AgentMessage])
agentLoop prompts ctx cfg streamFn cancel = do
  es <- newEventStream
  _ <- async $ do
    msgs <- runAgentLoop prompts ctx cfg streamFn cancel (pushEvent es)
    endStream es msgs
  pure es

{- | Continue an agent loop from the existing context without adding a message.
The last message in the context must not be an 'AssistantMessage'.
-}
agentLoopContinue ::
  AgentContext ->
  AgentLoopConfig ->
  StreamFn ->
  Maybe (IO Bool) ->
  IO (EventStream AgentEvent [AgentMessage])
agentLoopContinue ctx cfg streamFn cancel = do
  es <- newEventStream
  _ <- async $ do
    msgs <- runAgentLoopContinue ctx cfg streamFn cancel (pushEvent es)
    endStream es msgs
  pure es

-- ─── Low-level entry points ───────────────────────────────────────────────

-- | Like 'agentLoop' but drives events into an 'AgentEventSink'.
runAgentLoop ::
  [AgentMessage] ->
  AgentContext ->
  AgentLoopConfig ->
  StreamFn ->
  Maybe (IO Bool) ->
  AgentEventSink ->
  IO [AgentMessage]
runAgentLoop prompts ctx cfg streamFn cancel emit = do
  ctxRef <- newIORef ctx {acMessages = acMessages ctx <> prompts}
  newRef <- newIORef prompts
  emit EvAgentStart
  emit EvTurnStart
  forM_ prompts $ \m -> emit (EvMessageStart m) >> emit (EvMessageEnd m)
  runLoop ctxRef newRef cfg streamFn cancel emit
  readIORef newRef

-- | Like 'agentLoopContinue' but uses an 'AgentEventSink'.
runAgentLoopContinue ::
  AgentContext ->
  AgentLoopConfig ->
  StreamFn ->
  Maybe (IO Bool) ->
  AgentEventSink ->
  IO [AgentMessage]
runAgentLoopContinue ctx cfg streamFn cancel emit = do
  case acMessages ctx of
    [] -> ioError $ userError "Cannot continue: no messages in context"
    msgs
      | messageRole (last msgs) == "assistant" ->
          ioError $ userError "Cannot continue from an assistant message"
      | otherwise -> pure ()
  ctxRef <- newIORef ctx
  newRef <- newIORef ([] :: [AgentMessage])
  emit EvAgentStart
  emit EvTurnStart
  runLoop ctxRef newRef cfg streamFn cancel emit
  readIORef newRef

-- ─── Core two-level loop ──────────────────────────────────────────────────

{- | Outer loop: continue when follow-up messages arrive after the agent stops.
Inner loop: process tool calls and steering messages for one conversation turn.
-}
runLoop ::
  IORef AgentContext ->
  IORef [AgentMessage] ->
  AgentLoopConfig ->
  StreamFn ->
  Maybe (IO Bool) ->
  AgentEventSink ->
  IO ()
runLoop ctxRef newRef cfg streamFn cancel emit = do
  steering0 <- fromMaybe (pure []) (alcGetSteeringMessages cfg)
  pendingRef <- newIORef steering0
  firstTurnRef <- newIORef True

  let outerLoop = do
        innerLoop
        followUps <- fromMaybe (pure []) (alcGetFollowUpMessages cfg)
        unless (null followUps) $ do
          writeIORef pendingRef followUps
          outerLoop

      innerLoop = do
        pending <- readIORef pendingRef
        ctx <- readIORef ctxRef

        -- On first iteration we already emitted turn_start from the entry point
        firstTurn <- readIORef firstTurnRef
        if firstTurn
          then writeIORef firstTurnRef False
          else unless (null pending) $ emit EvTurnStart

        -- Flush pending steering / follow-up messages into context
        unless (null pending) $ do
          forM_ pending $ \m -> do
            emit (EvMessageStart m)
            emit (EvMessageEnd m)
            modifyIORef' ctxRef $ \c -> c {acMessages = acMessages c <> [m]}
            modifyIORef' newRef (<> [m])
          writeIORef pendingRef []

        -- Stream one assistant turn
        ctx' <- readIORef ctxRef
        msg <- streamAssistantResponse ctx' cfg streamFn cancel emit
        modifyIORef' newRef (<> [msg])

        case msg of
          AssistantMessage {amStopReason = r}
            | r == StopError || r == StopAborted -> do
                emit (EvTurnEnd msg [])
          _ -> do
            let toolCalls = extractToolCalls msg
            if null toolCalls
              then emit (EvTurnEnd msg [])
              else do
                ctx'' <- readIORef ctxRef
                results <- executeToolCalls ctx'' msg toolCalls cfg cancel emit
                forM_ results $ \r -> do
                  modifyIORef' ctxRef $ \c -> c {acMessages = acMessages c <> [r]}
                  modifyIORef' newRef (<> [r])
                emit (EvTurnEnd msg results)
                newSteering <- fromMaybe (pure []) (alcGetSteeringMessages cfg)
                modifyIORef' pendingRef (<> newSteering)
                -- Continue the inner loop when there were tool calls or new steering
                innerLoop

  outerLoop
  msgs <- readIORef newRef
  emit (EvAgentEnd msgs)

-- ─── Streaming one assistant turn ─────────────────────────────────────────

streamAssistantResponse ::
  AgentContext ->
  AgentLoopConfig ->
  StreamFn ->
  Maybe (IO Bool) ->
  AgentEventSink ->
  IO Message
streamAssistantResponse ctx cfg streamFn _cancel emit = do
  -- Optional context transform (pruning, injection, …)
  msgs <- case alcTransformContext cfg of
    Nothing -> pure (acMessages ctx)
    Just f -> f (acMessages ctx)

  -- Convert to LLM-compatible messages
  llmMsgs <- alcConvertToLlm cfg msgs

  -- Dynamic API key (important for expiring OAuth tokens)
  let opts = alcStreamOptions cfg
  dynamicKey <- case alcGetApiKey cfg of
    Nothing -> pure Nothing
    Just f -> f (modelProvider (alcModel cfg))
  let apiKey = dynamicKey <|> soApiKey opts -- dynamic key takes precedence
  let llmCtx =
        LLMContext
          { lcSystemPrompt = acSystemPrompt ctx
          , lcMessages = llmMsgs
          , lcTools = case acTools ctx of
              [] -> Nothing
              tools -> Just (map toAgentLLMTool tools)
          }
      opts' = opts {soApiKey = apiKey}

  stream <- streamFn (alcModel cfg) llmCtx opts'
  addedRef <- newIORef False

  let handleEvent ev = do
        let p = eventPartial ev
        case ev of
          EvStart _ -> do
            writeIORef addedRef True
            emit (EvMessageStart (partialToFinal p))
          EvDone _ -> pure ()
          EvError _ _ -> pure ()
          _ -> do
            added <- readIORef addedRef
            when added $
              emit (EvMessageUpdate (partialToFinal p) ev)

  finalPartial <- foldStream stream handleEvent
  let finalMsg = partialToFinal finalPartial
  added <- readIORef addedRef
  unless added $ emit (EvMessageStart finalMsg)
  emit (EvMessageEnd finalMsg)
  pure finalMsg

toAgentLLMTool :: AgentTool -> LLMTool
toAgentLLMTool t =
  LLMTool
    { ltName = atName t
    , ltDescription = atDescription t
    , ltSchema = atSchema t
    }

extractToolCalls :: Message -> [ToolCall]
extractToolCalls (AssistantMessage {amBlocks = blocks}) =
  [tc | ABToolCall tc <- blocks]
extractToolCalls _ = []

-- ─── Tool execution ───────────────────────────────────────────────────────

executeToolCalls ::
  AgentContext ->
  -- | assistant message that requested these calls
  Message ->
  [ToolCall] ->
  AgentLoopConfig ->
  Maybe (IO Bool) ->
  AgentEventSink ->
  IO [Message]
executeToolCalls ctx assistantMsg toolCalls cfg cancel emit =
  case alcToolExecution cfg of
    Sequential -> executeSequential ctx assistantMsg toolCalls cfg cancel emit
    Parallel -> executeParallel ctx assistantMsg toolCalls cfg cancel emit

executeSequential ::
  AgentContext ->
  Message ->
  [ToolCall] ->
  AgentLoopConfig ->
  Maybe (IO Bool) ->
  AgentEventSink ->
  IO [Message]
executeSequential ctx assistantMsg toolCalls cfg cancel emit =
  forM toolCalls $ \tc -> do
    emit (EvToolExecStart (tcId tc) (tcName tc) (tcArguments tc))
    prep <- prepareCall ctx assistantMsg tc cfg cancel
    case prep of
      Immediate result isErr -> emitOutcome tc result isErr emit
      Prepared pc -> do
        executed <- runCall pc cancel emit
        finalizeCall ctx assistantMsg pc executed cfg cancel emit

{- | Preflight all calls sequentially (for hook ordering guarantees),
then execute the allowed subset concurrently, collecting results in
original source order.
-}
executeParallel ::
  AgentContext ->
  Message ->
  [ToolCall] ->
  AgentLoopConfig ->
  Maybe (IO Bool) ->
  AgentEventSink ->
  IO [Message]
executeParallel ctx assistantMsg toolCalls cfg cancel emit = do
  -- Phase 1: prepare all calls (validate + beforeToolCall hook) sequentially
  preparations <- forM toolCalls $ \tc -> do
    emit (EvToolExecStart (tcId tc) (tcName tc) (tcArguments tc))
    (tc,) <$> prepareCall ctx assistantMsg tc cfg cancel

  -- Phase 2: split while preserving relative order
  let (immList, runList) = foldl' split ([], []) preparations
      split (imm, run) (tc, Immediate r e) = (imm <> [(tc, r, e)], run)
      split (imm, run) (_, Prepared pc) = (imm, run <> [pc])

  -- Phase 3: emit immediate (blocked/error) results
  immediateResults <- forM immList $ \(tc, r, e) -> emitOutcome tc r e emit

  -- Phase 4: start runnable calls concurrently, then await in source order
  running <- forM runList $ \pc ->
    (pc,) <$> async (runCall pc cancel emit)
  parallelResults <- forM running $ \(pc, a) -> do
    executed <- wait a
    finalizeCall ctx assistantMsg pc executed cfg cancel emit

  pure (immediateResults <> parallelResults)

-- ─── Individual call lifecycle ────────────────────────────────────────────

data CallPreparation
  = -- | result, isError
    Immediate (AgentToolResult Value) Bool
  | Prepared PreparedCall

data PreparedCall = PreparedCall
  { pcToolCall :: ToolCall
  , pcTool :: AgentTool
  , pcArgs :: Value
  }

prepareCall ::
  AgentContext ->
  -- | assistant message
  Message ->
  ToolCall ->
  AgentLoopConfig ->
  Maybe (IO Bool) ->
  IO CallPreparation
prepareCall ctx assistantMsg tc cfg _cancel = do
  case find (\t -> atName t == tcName tc) (acTools ctx) of
    Nothing ->
      pure $ Immediate (mkErrResult ("Tool not found: " <> tcName tc)) True
    Just tool -> do
      rawArgs <- case atPrepareArgs tool of
        Nothing -> pure (tcArguments tc)
        Just f -> f (tcArguments tc)

      case atValidateArgs tool rawArgs of
        Left errMsg ->
          pure $ Immediate (mkErrResult errMsg) True
        Right validArgs -> do
          blockResult <- case alcBeforeToolCall cfg of
            Nothing -> pure Nothing
            Just f ->
              f $
                BeforeToolCallContext
                  { btcAssistantMsg = assistantMsg
                  , btcToolCall = tc
                  , btcArgs = validArgs
                  , btcAgentCtx = ctx
                  }
          case blockResult of
            Just (BlockCall reason) ->
              pure $
                Immediate
                  (mkErrResult (fromMaybe "Tool execution was blocked" reason))
                  True
            _ ->
              pure $
                Prepared
                  PreparedCall
                    { pcToolCall = tc {tcArguments = validArgs}
                    , pcTool = tool
                    , pcArgs = validArgs
                    }

-- | Execute a prepared call, catching all exceptions.
runCall ::
  PreparedCall ->
  Maybe (IO Bool) ->
  AgentEventSink ->
  IO (AgentToolResult Value, Bool)
runCall pc cancel emit = do
  let onUpdate partial =
        emit $
          EvToolExecUpdate
            (tcId (pcToolCall pc))
            (tcName (pcToolCall pc))
            (tcArguments (pcToolCall pc))
            (toolResDetails partial)
  result <-
    try @SomeException $
      atExecute
        (pcTool pc)
        (tcId (pcToolCall pc))
        (pcArgs pc)
        cancel
        (Just onUpdate)
  pure $ case result of
    Right r -> (r, False)
    Left err -> (mkErrResult (Text.pack (show err)), True)

-- | Apply afterToolCall hook overrides, then emit the final outcome.
finalizeCall ::
  AgentContext ->
  Message ->
  PreparedCall ->
  (AgentToolResult Value, Bool) ->
  AgentLoopConfig ->
  Maybe (IO Bool) ->
  AgentEventSink ->
  IO Message
finalizeCall ctx assistantMsg pc (result, isErr) cfg _cancel emit = do
  (result', isErr') <- case alcAfterToolCall cfg of
    Nothing -> pure (result, isErr)
    Just f -> do
      override <-
        f $
          AfterToolCallContext
            { atcAssistantMsg = assistantMsg
            , atcToolCall = pcToolCall pc
            , atcArgs = pcArgs pc
            , atcResult = result
            , atcIsError = isErr
            , atcAgentCtx = ctx
            }
      pure $ case override of
        Nothing -> (result, isErr)
        Just ov ->
          ( result
              { toolResContent = fromMaybe (toolResContent result) (overContent ov)
              , toolResDetails = fromMaybe (toolResDetails result) (overDetails ov)
              }
          , fromMaybe isErr (overIsError ov)
          )
  emitOutcome (pcToolCall pc) result' isErr' emit

-- | Emit tool execution end + message events, returning the ToolResultMessage.
emitOutcome ::
  ToolCall ->
  AgentToolResult Value ->
  Bool ->
  AgentEventSink ->
  IO Message
emitOutcome tc result isErr emit = do
  emit $ EvToolExecEnd (tcId tc) (tcName tc) (toolResDetails result) isErr
  ts <- currentTimestamp
  let msg =
        ToolResultMessage
          { trmToolCallId = tcId tc
          , trmToolName = tcName tc
          , trmContent = toolResContent result
          , trmDetails = toolResDetails result
          , trmIsError = isErr
          , trmTimestamp = ts
          }
  emit (EvMessageStart msg)
  emit (EvMessageEnd msg)
  pure msg

-- ─── Utilities ────────────────────────────────────────────────────────────

mkErrResult :: Text -> AgentToolResult Value
mkErrResult msg =
  AgentToolResult
    { toolResContent = [mkTextBlock msg]
    , toolResDetails = toJSON ()
    }

currentTimestamp :: IO Int64
currentTimestamp = round . (* 1000) <$> getPOSIXTime

-- | @(<|>)@ for 'Maybe': prefer the left value when both are present.
(<|>) :: Maybe a -> Maybe a -> Maybe a
Just l <|> _ = Just l
Nothing <|> r = r

infixl 3 <|>
