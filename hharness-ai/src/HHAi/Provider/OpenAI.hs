{- | OpenAI provider for both Chat Completions and Responses APIs.

Uses raw @http-client@ (the Mercury @openai@ package is not in the
dependency set).  Both APIs stream via SSE over HTTPS.

-   __openai-completions__: @POST /v1/chat/completions@ with @stream: true@
-   __openai-responses__:   @POST /v1/responses@        with @stream: true@
-}
module HHAi.Provider.OpenAI (
  openaiCompletionsStreamFn,
  openaiResponsesStreamFn,
  openaiCompletionsApiProvider,
  openaiResponsesApiProvider,
  registerOpenAI,
) where

import Control.Concurrent.Async (async)
import Control.Exception (SomeException, try)
import Control.Monad (unless, void, when)
import Data.Aeson (Value (..), eitherDecode, encode, object, toJSON, (.=))
import Data.Aeson.Key qualified as AK
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as LBS
import Data.ByteString.Lazy.Char8 qualified as LBSC8
import Data.Function ((&))
import Data.IORef
import Data.Int (Int64)
import Data.List (foldl')
import Data.Maybe (fromMaybe, isJust)
import Data.Scientific (fromFloatDigits)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (encodeUtf8)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Vector qualified as Vector
import Network.HTTP.Client (
  BodyReader,
  Request,
  RequestBody (RequestBodyLBS),
  brRead,
  httpLbs,
  method,
  newManager,
  parseRequest,
  requestBody,
  requestHeaders,
  responseBody,
  responseStatus,
  withResponse,
 )
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Status (statusCode)

import HHAi.Registry (ApiProvider (..), ApiRegistry, registerApiProvider)
import HHAi.Stream (EventStream, endStream, newEventStream, pushEvent)
import HHAi.Types

-- ─── Public API ────────────────────────────────────────────────────────────

openaiCompletionsStreamFn :: StreamFn
openaiCompletionsStreamFn model ctx opts = do
  es <- newEventStream
  _ <- async $ streamChatCompletion model ctx opts es
  pure es

openaiResponsesStreamFn :: StreamFn
openaiResponsesStreamFn model ctx opts = do
  es <- newEventStream
  _ <- async $ streamResponses model ctx opts es
  pure es

openaiCompletionsApiProvider :: ApiProvider
openaiCompletionsApiProvider =
  ApiProvider
    { apApi = "openai-completions"
    , apStream = openaiCompletionsStreamFn
    , apStreamSimple = \model ctx sso -> openaiCompletionsStreamFn model ctx (simpleToStreamOpts sso)
    }

openaiResponsesApiProvider :: ApiProvider
openaiResponsesApiProvider =
  ApiProvider
    { apApi = "openai-responses"
    , apStream = openaiResponsesStreamFn
    , apStreamSimple = \model ctx sso -> openaiResponsesStreamFn model ctx (simpleToStreamOpts sso)
    }

registerOpenAI :: ApiRegistry -> IO ()
registerOpenAI registry = do
  registerApiProvider registry openaiCompletionsApiProvider
  registerApiProvider registry openaiResponsesApiProvider

-- ═════════════════════════════════════════════════════════════════════════════
--  Chat Completions API
-- ═════════════════════════════════════════════════════════════════════════════

streamChatCompletion :: Model -> Context -> StreamOptions -> EventStream AssistantMessageEvent AssistantMessage -> IO ()
streamChatCompletion model ctx opts es = do
  ts <- nowMs
  let baseUrl = if Text.null (mBaseUrl model) then "https://api.openai.com" else mBaseUrl model
  er <- try @SomeException $ do
    reqJson <- either (fail . Text.unpack) pure $ mkChatCompletionRequest model ctx opts
    reqHttp <- mkPostRequest baseUrl (fromMaybe "" (soApiKey opts)) "/v1/chat/completions" reqJson
    sseStream reqHttp (chatCompletionDeltaHandler es ts model)
  case er of
    Left e -> pushErr es ts (Text.pack (show e))
    Right (Just msg) -> endStream es msg
    Right Nothing -> void $ finalizeWithStop es ts model StopEndTurn

-- ═════════════════════════════════════════════════════════════════════════════
--  Responses API
-- ═════════════════════════════════════════════════════════════════════════════

streamResponses :: Model -> Context -> StreamOptions -> EventStream AssistantMessageEvent AssistantMessage -> IO ()
streamResponses model ctx opts es = do
  ts <- nowMs
  let baseUrl = if Text.null (mBaseUrl model) then "https://api.openai.com" else mBaseUrl model
  er <- try @SomeException $ do
    reqJson <- either (fail . Text.unpack) pure $ mkResponsesRequest model ctx opts
    reqHttp <- mkPostRequest baseUrl (fromMaybe "" (soApiKey opts)) "/v1/responses" reqJson
    sseStream reqHttp (responsesDeltaHandler es ts model)
  case er of
    Left e -> pushErr es ts (Text.pack (show e))
    Right (Just msg) -> endStream es msg
    Right Nothing -> void $ finalizeWithStop es ts model StopEndTurn

-- ═════════════════════════════════════════════════════════════════════════════
--  HTTP / SSE
-- ═════════════════════════════════════════════════════════════════════════════

mkPostRequest :: Text -> Text -> Text -> Value -> IO Request
mkPostRequest baseUrl apiKey path body = do
  initReq <- parseRequest $ Text.unpack (stripTrailingSlash baseUrl <> path)
  pure
    initReq
      { method = "POST"
      , requestHeaders =
          [ ("Content-Type", "application/json")
          , ("Authorization", "Bearer " <> encodeUtf8 apiKey)
          , ("Accept", "text/event-stream")
          ]
      , requestBody = RequestBodyLBS (encode body)
      }

{- | Open an HTTP response, verify 200, then read the SSE body line-by-line.
The handler folds each @data: {…}@ JSON payload.  Once the stream ends it
returns the final 'AssistantMessage' (or 'Nothing' if the handler already
signalled completion, e.g. via [DONE]).
-}
sseStream :: Request -> (Value -> IO (Maybe AssistantMessage)) -> IO (Maybe AssistantMessage)
sseStream reqHttp handler = do
  manager <- newManager tlsManagerSettings
  withResponse reqHttp manager $ \resp -> do
    let code = statusCode (responseStatus resp)
    unless (code == 200) $ do
      body <- LBS.fromStrict <$> brRead (responseBody resp)
      ioError $ userError $ "HTTP " ++ show code ++ " " ++ LBSC8.unpack body
    processSse (responseBody resp) handler

processSse :: BodyReader -> (Value -> IO (Maybe AssistantMessage)) -> IO (Maybe AssistantMessage)
processSse br handler = go mempty Nothing
  where
    go buf mResult = do
      chunkBS <- brRead br
      let chunk = LBS.fromStrict chunkBS
      if LBS.null chunk
        then pure mResult
        else do
          let (lines', buf') = splitLines (buf <> chunk)
          mResult' <- foldlM handleLine mResult lines'
          go buf' mResult'

    foldlM _ z [] = pure z
    foldlM f z (x : xs) = f z x >>= \z' -> foldlM f z' xs

    handleLine mRes line = do
      let stripped = LBS.dropWhile (== 32) line
      if LBSC8.isPrefixOf "data: " stripped
        then do
          let payload = LBS.drop 6 stripped
          if payload == "[DONE]"
            then pure mRes
            else case eitherDecode @Value payload of
              Left _ -> pure mRes
              Right val -> do
                m <- handler val
                pure (m <|> mRes)
        else pure mRes

    m <|> (Just _) = m
    _ <|> r = r

splitLines :: LBS.ByteString -> ([LBS.ByteString], LBS.ByteString)
splitLines = go []
  where
    go acc b =
      case LBSC8.elemIndex '\n' b of
        Nothing -> (reverse acc, b)
        Just i ->
          let (line, rest) = LBS.splitAt i b
              rest' = LBS.drop 1 rest
           in go (line : acc) rest'

-- ═════════════════════════════════════════════════════════════════════════════
--  Chat Completions  –  SSE delta handler
-- ═════════════════════════════════════════════════════════════════════════════

{- | Accumulates a streaming assistant response across many SSE chunks.
State is kept in an 'IORef' so that each @delta@ JSON fragment can extend
partial text / tool-call arguments.
-}
chatCompletionDeltaHandler ::
  EventStream AssistantMessageEvent AssistantMessage ->
  Int64 ->
  Model ->
  Value ->
  IO (Maybe AssistantMessage)
chatCompletionDeltaHandler es ts model val = do
  case val of
    Object obj
      | Just (Array choices) <- KM.lookup "choices" obj
      , not (Vector.null choices) ->
          case Vector.head choices of
            Object choiceObj ->
              case KM.lookup "delta" choiceObj of
                Just (Object delta) ->
                  let finishReason = parseFinishReason (KM.lookup "finish_reason" choiceObj)
                   in processCompletionDelta es ts model delta finishReason
                _ ->
                  pure Nothing
            _ ->
              pure Nothing
    _ ->
      pure Nothing

{- | Mutable accumulator for the text / tool_calls state of one streaming
response.  OpenAI sends tool-call arguments as a series of tiny string
fragments, so we keep a map keyed by the @index@ field.
-}
data PartialState = PartialState
  { psStarted :: Bool
  , psText :: Text
  , psThinking :: Text
  , psToolCalls :: [(Int, PartialToolCall)]
  -- ^ index -> partial tool call (preserves arrival order)
  }

emptyPartialState :: PartialState
emptyPartialState = PartialState False "" "" []

data PartialToolCall = PartialToolCall
  { ptcId :: Text
  , ptcName :: Text
  , ptcArgs :: Text
  }

processCompletionDelta ::
  EventStream AssistantMessageEvent AssistantMessage ->
  Int64 ->
  Model ->
  KM.KeyMap Value ->
  Maybe StopReason ->
  IO (Maybe AssistantMessage)
processCompletionDelta es ts model delta finishReason = do
  stateRef <- newIORef emptyPartialState

  -- 1. Emit start on first non-empty delta
  let content = case (KM.lookup "content" delta, KM.lookup "role" delta) of
        (Just (String c), _) | not (Text.null c) -> Just c
        (_, Just (String "assistant")) -> Just ""
        _ -> Nothing
      thinking = case KM.lookup "reasoning" delta of
        Just (String t) -> Just t
        _ -> Nothing
      toolDeltas = case KM.lookup "tool_calls" delta of
        Just (Array tds) -> Vector.toList tds
        _ -> []

  when (isJust content || isJust thinking || not (null toolDeltas)) $ do
    let partial = emptyPartial ts
    pushEvent es (EvStart partial)
    modifyIORef' stateRef (\s -> s {psStarted = True})

  -- 2. Accumulate & emit text delta
  case content of
    Just text | not (Text.null text) -> do
      let partial = emptyPartial ts
      pushEvent es (EvTextDelta 0 text partial)
      modifyIORef' stateRef (\s -> s {psText = psText s <> text})
    _ -> pure ()

  -- 3. Accumulate & emit thinking delta
  case thinking of
    Just text | not (Text.null text) -> do
      let partial = emptyPartial ts
      pushEvent es (EvThinkingDelta 0 text partial)
      modifyIORef' stateRef (\s -> s {psThinking = psThinking s <> text})
    _ -> pure ()

  -- 4. Accumulate tool-call deltas
  mapM_ (processToolDelta stateRef es ts) toolDeltas

  -- 5. Finish if we have a stop reason
  case finishReason of
    Just sr -> do
      s <- readIORef stateRef
      let blocks = buildBlocks s
          finalMsg =
            AssistantMessage
              { amContent = blocks
              , amApi = mApi model
              , amProvider = mProvider model
              , amModel = mId model
              , amResponseId = Nothing
              , amUsage = defaultUsage
              , amStopReason = sr
              , amErrorMessage = Nothing
              , amTimestamp = ts
              }
      pushEvent es (EvDone sr finalMsg)
      pure (Just finalMsg)
    Nothing -> pure Nothing

buildBlocks :: PartialState -> [AssistantContent]
buildBlocks s =
  let txtBlocks = [ACText (TextContent (psText s) Nothing) | not (Text.null (psText s))]
      thinkBlocks = [ACThinking (ThinkingContent (psThinking s) Nothing Nothing) | not (Text.null (psThinking s))]
      tcBlocks = map (\(_, ptc) -> ACToolCall (ToolCall (ptcId ptc) (ptcName ptc) (fromStr (ptcArgs ptc)) Nothing)) (psToolCalls s)
   in txtBlocks <> thinkBlocks <> tcBlocks
  where
    fromStr str = case eitherDecode (LBSC8.pack (Text.unpack str)) of
      Right v -> v
      Left _ -> toJSON str

processToolDelta ::
  IORef PartialState ->
  EventStream AssistantMessageEvent AssistantMessage ->
  Int64 ->
  Value ->
  IO ()
processToolDelta stateRef es ts val =
  case val of
    Object obj -> do
      let mIdx = case KM.lookup "index" obj of
            Just (Number n) -> floor n
            _ -> 0
          mId_ = case KM.lookup "id" obj of
            Just (String i) | not (Text.null i) -> Just i
            _ -> Nothing
          mName = case KM.lookup "function" obj of
            Just (Object f) -> case KM.lookup "name" f of
              Just (String n) | not (Text.null n) -> Just n
              _ -> Nothing
            _ -> Nothing
          mArgs = case KM.lookup "function" obj of
            Just (Object f) -> case KM.lookup "arguments" f of
              Just (String a) -> Just a
              _ -> Nothing
            _ -> Nothing
      modifyIORef' stateRef $ \s ->
        let existing = lookup mIdx (psToolCalls s)
            updated = case existing of
              Nothing ->
                PartialToolCall
                  { ptcId = fromMaybe "" mId_
                  , ptcName = fromMaybe "" mName
                  , ptcArgs = fromMaybe "" mArgs
                  }
              Just ptc ->
                ptc
                  { ptcId = if not (Text.null (ptcId ptc)) then ptcId ptc else fromMaybe "" mId_
                  , ptcName = if not (Text.null (ptcName ptc)) then ptcName ptc else fromMaybe "" mName
                  , ptcArgs = ptcArgs ptc <> fromMaybe "" mArgs
                  }
            others = filter ((/= mIdx) . fst) (psToolCalls s)
         in s {psToolCalls = others <> [(mIdx, updated)]}
      -- Emit events for completed tool calls (when we see a full id+name+args)
      case (mId_, mName) of
        (Just cid, Just name) | not (Text.null cid) && not (Text.null name) ->
          do
            s <- readIORef stateRef
            case lookup mIdx (psToolCalls s) of
              Just ptc | not (Text.null (ptcArgs ptc)) ->
                do
                  let tc = ToolCall cid name (fromStr (ptcArgs ptc)) Nothing
                      partial = emptyPartial ts
                  pushEvent es (EvToolCallStart mIdx partial)
                  pushEvent es (EvToolCallDelta mIdx "" partial)
                  pushEvent es (EvToolCallEnd mIdx tc partial)
              _ ->
                pure ()
        _ ->
          pure ()
    _ ->
      pure ()
  where
    fromStr str = case eitherDecode (LBSC8.pack (Text.unpack str)) of
      Right v -> v
      Left _ -> toJSON str

-- ═════════════════════════════════════════════════════════════════════════════
--  Responses API  –  SSE delta handler
-- ═════════════════════════════════════════════════════════════════════════════

responsesDeltaHandler ::
  EventStream AssistantMessageEvent AssistantMessage ->
  Int64 ->
  Model ->
  Value ->
  IO (Maybe AssistantMessage)
responsesDeltaHandler es ts model val = do
  case val of
    Object obj ->
      case (,) <$> KM.lookup "output" obj <*> KM.lookup "status" obj of
        Just (Array outs, String "completed") | not (Vector.null outs) ->
          case Vector.last outs of
            Object outObj ->
              let delta = case KM.lookup "content" outObj of
                    Just (Array cs)
                      | not (Vector.null cs) ->
                          Just (Vector.last cs)
                    Just v ->
                      Just v
                    _ ->
                      Nothing
                  finishReason = Just StopEndTurn
               in case delta of
                    Just (Object dObj) ->
                      processCompletionDelta es ts model dObj finishReason
                    _ ->
                      finalizeWithStop es ts model StopEndTurn
            _ ->
              finalizeWithStop es ts model StopEndTurn
        Just (Array outs, _) | not (Vector.null outs) ->
          case Vector.last outs of
            Object outObj ->
              let delta = case KM.lookup "content" outObj of
                    Just (Array cs)
                      | not (Vector.null cs) ->
                          Just (Vector.last cs)
                    Just v ->
                      Just v
                    _ ->
                      Nothing
                  finishReason = Nothing
               in case delta of
                    Just (Object dObj) ->
                      processCompletionDelta es ts model dObj finishReason
                    _ ->
                      pure Nothing
            _ ->
              pure Nothing
        _ ->
          pure Nothing
    _ ->
      pure Nothing

-- ═════════════════════════════════════════════════════════════════════════════
--  Request builders
-- ═════════════════════════════════════════════════════════════════════════════

mkChatCompletionRequest :: Model -> Context -> StreamOptions -> Either Text Value
mkChatCompletionRequest model ctx opts = do
  let msgs = insertSystem ctx (map messageToChatMessage (cMessages ctx))
      bodyPairs =
        [("model", String (mId model)), ("messages", Array (Vector.fromList msgs)), ("stream", Bool True)]
          <> maybePair "temperature" (fmap (Number . fromFloatDigits) (soTemperature opts))
          <> maybePair "max_tokens" (fmap (Number . fromIntegral) (soMaxTokens opts))
          <> maybePair "tools" (fmap (Array . Vector.fromList . map toolToOpenAI) (cTools ctx))
          <> maybePair "tool_choice" (fmap String (if isJust (cTools ctx) then Just "auto" else Nothing))
  Right (Object (KM.fromList bodyPairs))

mkResponsesRequest :: Model -> Context -> StreamOptions -> Either Text Value
mkResponsesRequest model ctx opts = do
  let msgs = insertSystemCtx ctx (map messageToResponsesMessage (cMessages ctx))
      bodyPairs =
        [("model", String (mId model)), ("input", Array (Vector.fromList msgs)), ("stream", Bool True)]
          <> maybePair "temperature" (fmap (Number . fromFloatDigits) (soTemperature opts))
          <> maybePair "max_tokens" (fmap (Number . fromIntegral) (soMaxTokens opts))
          <> maybePair "tools" (fmap (Array . Vector.fromList . map toolToOpenAI) (cTools ctx))
          <> maybePair "tool_choice" (fmap String (if isJust (cTools ctx) then Just "auto" else Nothing))
  Right (Object (KM.fromList bodyPairs))

insertSystem :: Context -> [Value] -> [Value]
insertSystem ctx msgs =
  case cSystemPrompt ctx of
    Nothing -> msgs
    Just sp -> object [("role", String "system"), ("content", String sp)] : msgs

insertSystemCtx :: Context -> [Value] -> [Value]
insertSystemCtx ctx msgs =
  case cSystemPrompt ctx of
    Nothing -> msgs
    Just sp -> object [("role", String "system"), ("content", String sp)] : msgs

maybePair :: Text -> Maybe Value -> [(KM.Key, Value)]
maybePair _ Nothing = []
maybePair k (Just v) = [(AK.fromText k, v)]

-- ─── Chat Completions message format ───────────────────────────────────────

messageToChatMessage :: Message -> Value
messageToChatMessage (MsgUser UserMessage {umContent = cs}) =
  object
    [ "role" .= String "user"
    , "content" .= if any isImage cs then Array (Vector.fromList (map contentToOpenAI cs)) else textFromContent cs
    ]
messageToChatMessage (MsgAssistant AssistantMessage {amContent = cs}) =
  let toolCalls = [tc | ACToolCall tc <- cs]
      textParts = [t | ACText (TextContent t _) <- cs]
      body =
        [("role", String "assistant"), ("content", String (Text.concat textParts))]
          <> [("tool_calls", Array (Vector.fromList (map toolCallToOpenAI toolCalls))) | not (null toolCalls)]
   in Object (KM.fromList body)
messageToChatMessage (MsgToolResult ToolResultMessage {trmToolCallId = tid, trmContent = cs, trmIsError = isErr}) =
  object
    [ "role" .= String "tool"
    , "tool_call_id" .= String tid
    , "content" .= textFromToolResultContent cs
    ]

isImage :: UserContent -> Bool
isImage (UCImage _) = True
isImage _ = False

textFromContent :: [UserContent] -> Value
textFromContent cs = String (Text.concat [t | UCText (TextContent t _) <- cs])

contentToOpenAI :: UserContent -> Value
contentToOpenAI (UCText (TextContent t _)) =
  object [("type", String "text"), ("text", String t)]
contentToOpenAI (UCImage (ImageContent d mt)) =
  object
    [ ("type", String "image_url")
    , ("image_url", object [("url", String d), ("detail", String "auto")])
    ]

toolCallToOpenAI :: ToolCall -> Value
toolCallToOpenAI (ToolCall i n a _) =
  object
    [ ("id", String i)
    , ("type", String "function")
    , ("function", object [("name", String n), ("arguments", a)])
    ]

-- ─── Responses API message format ──────────────────────────────────────────

messageToResponsesMessage :: Message -> Value
messageToResponsesMessage (MsgUser UserMessage {umContent = cs}) =
  object
    [ ("role", String "user")
    , ("content", if any isImage cs then Array (Vector.fromList (map contentToOpenAI cs)) else textFromContent cs)
    ]
messageToResponsesMessage (MsgAssistant AssistantMessage {amContent = cs}) =
  let textParts = Text.concat [t | ACText (TextContent t _) <- cs]
      thinkingParts = Text.concat [t | ACThinking (ThinkingContent t _ _) <- cs]
      toolCalls = [tc | ACToolCall tc <- cs]
      body =
        [("role", String "assistant")]
          <> if Text.null textParts
            then []
            else
              [("content", String textParts)]
                <> if Text.null thinkingParts
                  then []
                  else
                    [("reasoning", String thinkingParts)]
                      <> [("tool_calls", Array (Vector.fromList (map toolCallToOpenAI toolCalls))) | not (null toolCalls)]
   in Object (KM.fromList body)
messageToResponsesMessage (MsgToolResult ToolResultMessage {trmToolCallId = tid, trmContent = cs}) =
  object
    [ ("role", String "tool")
    , ("tool_call_id", String tid)
    , ("content", textFromToolResultContent cs)
    ]

-- ─── Content helpers ───────────────────────────────────────────────────────

textFromToolResultContent :: [ToolResultContent] -> Value
textFromToolResultContent cs = String (Text.concat [t | TRCText (TextContent t _) <- cs])

toolToOpenAI :: Tool -> Value
toolToOpenAI t =
  object
    [ ("type", String "function")
    , ("function", object [("name", String (tName t)), ("description", String (tDescription t)), ("parameters", tParameters t)])
    ]

-- ═════════════════════════════════════════════════════════════════════════════
--  Helpers
-- ═════════════════════════════════════════════════════════════════════════════

parseFinishReason :: Maybe Value -> Maybe StopReason
parseFinishReason (Just (String "stop")) = Just StopEndTurn
parseFinishReason (Just (String "tool_calls")) = Just StopToolUse
parseFinishReason (Just (String "length")) = Just StopMaxTokens
parseFinishReason (Just (String "content_filter")) = Just StopError
parseFinishReason _ = Nothing

finalizeWithStop ::
  EventStream AssistantMessageEvent AssistantMessage ->
  Int64 ->
  Model ->
  StopReason ->
  IO (Maybe AssistantMessage)
finalizeWithStop es ts model sr = do
  let finalMsg =
        AssistantMessage
          { amContent = []
          , amApi = mApi model
          , amProvider = mProvider model
          , amModel = mId model
          , amResponseId = Nothing
          , amUsage = defaultUsage
          , amStopReason = sr
          , amErrorMessage = Nothing
          , amTimestamp = ts
          }
  pushEvent es (EvDone sr finalMsg)
  pure (Just finalMsg)

pushErr ::
  EventStream AssistantMessageEvent AssistantMessage ->
  Int64 ->
  Text ->
  IO ()
pushErr es ts msg = do
  let finalMsg =
        AssistantMessage
          { amContent = []
          , amApi = "openai"
          , amProvider = "openai"
          , amModel = ""
          , amResponseId = Nothing
          , amUsage = defaultUsage
          , amStopReason = StopError
          , amErrorMessage = Just msg
          , amTimestamp = ts
          }
  pushEvent es (EvError StopError msg finalMsg)
  endStream es finalMsg

simpleToStreamOpts :: SimpleStreamOptions -> StreamOptions
simpleToStreamOpts sso =
  StreamOptions
    { soApiKey = ssoApiKey sso
    , soTemperature = ssoTemperature sso
    , soMaxTokens = ssoMaxTokens sso
    , soThinking = ThinkingOff
    }

nowMs :: IO Int64
nowMs = round . (* 1000) <$> getPOSIXTime

stripTrailingSlash :: Text -> Text
stripTrailingSlash t =
  case Text.unsnoc t of
    Nothing -> t
    Just (rest, '/') -> stripTrailingSlash rest
    Just _ -> t
