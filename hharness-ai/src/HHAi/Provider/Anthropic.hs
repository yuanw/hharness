{- | Anthropic Messages API provider.

Bridge to Mercury's @claude@ package.
Implements 'StreamFn' via the blocking @/v1/messages@ endpoint.

Two entry points are provided:

* 'anthropicStreamFn' uses the library's typed @createMessage@ directly.
* 'anthropicStreamFnCompat' POSTs via @http-client@ and leniently patches
  JSON so proxies that omit @signature@ on thinking blocks still decode.
-}
module HHAi.Provider.Anthropic (
  anthropicStreamFn,
  anthropicStreamFnCompat,
  anthropicApiProvider,
  registerAnthropic,
  defaultAnthropicModelId,
) where

import Control.Concurrent.Async (async)
import Control.Exception (SomeException, try)
import Control.Monad (when)
import Data.Scientific (toBoundedInteger)

import Data.Aeson (Result (..), Value (..), eitherDecode, encode, fromJSON, toJSON)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as LBS
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (encodeUtf8)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Vector qualified as Vector
import Network.HTTP.Client (
  RequestBody (RequestBodyLBS),
  httpLbs,
  method,
  newManager,
  parseRequest,
  requestBody,
  requestHeaders,
  responseBody,
  responseStatus,
 )
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Status (statusCode)
import Numeric.Natural (Natural)

import Claude.V1 qualified as V1
import Claude.V1.Messages qualified as CM
import Claude.V1.Tool qualified as Tool

import HHAi.Registry (ApiProvider (..), ApiRegistry, registerApiProvider)
import HHAi.Stream (EventStream, endStream, newEventStream, pushEvent)
import HHAi.Types

-- ─── Public API ────────────────────────────────────────────────────────────

defaultAnthropicModelId :: Text
defaultAnthropicModelId = "claude-sonnet-4-5-20250929"

{- | Build a 'StreamFn' from Mercury's 'V1.Methods'.

Uses the library's @createMessage@ as-is (strict Anthropic JSON).
-}
anthropicStreamFn :: V1.Methods -> StreamFn
anthropicStreamFn methods model ctx opts = do
  es <- newEventStream
  _ <- async $ do
    ts <- nowMs
    let onErr = pushErr es ts
    r <- try @SomeException $ do
      req <- either (fail . Text.unpack) pure $ mkCreateMessage model ctx opts
      let V1.Methods {V1.createMessage = createMessage} = methods
      createMessage req
    finishStream es ts (mApi model) (mProvider model) model onErr r
  pure es

{- | Like 'anthropicStreamFn' but POSTs via @http-client@ and patches the JSON
before decoding so proxies that omit @"signature"@ on @type: "thinking"@
blocks still parse as 'CM.MessageResponse'.
-}
anthropicStreamFnCompat :: Maybe Text -> StreamFn
anthropicStreamFnCompat mVersion model ctx opts = do
  es <- newEventStream
  _ <- async $ do
    ts <- nowMs
    let baseUrl = if Text.null (mBaseUrl model) then "https://api.anthropic.com" else mBaseUrl model
        apiKey = fromMaybe "" (soApiKey opts)
        onErr = pushErr es ts
    r <- try @SomeException $ do
      req <- either (fail . Text.unpack) pure $ mkCreateMessage model ctx opts
      createMessageCompat baseUrl apiKey mVersion req
    finishStream es ts (mApi model) (mProvider model) model onErr r
  pure es

-- | Convenience: bundle the provider into an 'ApiProvider' record.
anthropicApiProvider :: V1.Methods -> ApiProvider
anthropicApiProvider methods =
  ApiProvider
    { apApi = "anthropic-messages"
    , apStream = anthropicStreamFn methods
    , apStreamSimple = \model ctx sso ->
        anthropicStreamFn methods model ctx (simpleToStreamOpts sso)
    }

-- | Register the Anthropic provider into a registry.
registerAnthropic :: ApiRegistry -> V1.Methods -> IO ()
registerAnthropic registry methods =
  registerApiProvider registry (anthropicApiProvider methods)

-- ─── Internal helpers ──────────────────────────────────────────────────────

simpleToStreamOpts :: SimpleStreamOptions -> StreamOptions
simpleToStreamOpts sso =
  StreamOptions
    { soApiKey = ssoApiKey sso
    , soTemperature = ssoTemperature sso
    , soMaxTokens = ssoMaxTokens sso
    , soThinking = ThinkingOff
    }

finishStream ::
  EventStream AssistantMessageEvent AssistantMessage ->
  Int64 ->
  Text ->
  Text ->
  Model ->
  (Text -> IO ()) ->
  Either SomeException CM.MessageResponse ->
  IO ()
finishStream es ts api provider model onErr = \case
  Left e -> onErr (Text.pack (show e))
  Right resp ->
    case messageResponseToAssistant ts api provider model resp of
      Left err -> onErr err
      Right finalMsg -> do
        let partial =
              PartialAssistantMessage
                { pamContent = amContent finalMsg
                , pamStopReason = amStopReason finalMsg
                , pamErrorMessage = amErrorMessage finalMsg
                , pamTimestamp = ts
                }
        pushEvent es (EvStart partial)
        endStream es finalMsg

pushErr ::
  EventStream AssistantMessageEvent AssistantMessage ->
  Int64 ->
  Text ->
  IO ()
pushErr es ts msg = do
  let final =
        AssistantMessage
          { amContent = []
          , amApi = "anthropic"
          , amProvider = "anthropic"
          , amModel = ""
          , amResponseId = Nothing
          , amUsage = defaultUsage
          , amStopReason = StopError
          , amErrorMessage = Just msg
          , amTimestamp = ts
          }
  pushEvent es (EvError StopError msg final)
  endStream es final

mkCreateMessage :: Model -> Context -> StreamOptions -> Either Text CM.CreateMessage
mkCreateMessage model ctx opts = do
  msgs <- traverse piMessageToClaude (cMessages ctx)
  let tools = case cTools ctx of
        Nothing -> Nothing
        Just defs -> Just $ Vector.fromList $ map toolToDefinition defs
      maxTok = fromMaybe (mMaxTokens model) (soMaxTokens opts)
  pure
    CM._CreateMessage
      { CM.model = resolveModelId model
      , CM.messages = Vector.fromList msgs
      , CM.max_tokens = toNaturalMax1 maxTok
      , CM.system =
          case cSystemPrompt ctx of
            Nothing -> Nothing
            Just sp -> if Text.null sp then Nothing else Just (CM.systemText sp)
      , CM.temperature = soTemperature opts
      , CM.tools = tools
      }

toolToDefinition :: Tool -> Tool.ToolDefinition
toolToDefinition t =
  Tool.inlineTool $
    Tool.functionTool
      (tName t)
      (Just (tDescription t))
      (tParameters t)

createMessageCompat :: Text -> Text -> Maybe Text -> CM.CreateMessage -> IO CM.MessageResponse
createMessageCompat baseUrl apiKey mAnthropicVersion req = do
  manager <- newManager tlsManagerSettings
  initReq <- parseRequest $ Text.unpack (stripTrailingSlash baseUrl <> "/v1/messages")
  let version = fromMaybe "2023-06-01" mAnthropicVersion
      reqHttp =
        initReq
          { method = "POST"
          , requestHeaders =
              [ ("Content-Type", "application/json")
              , ("x-api-key", encodeUtf8 apiKey)
              , ("anthropic-version", encodeUtf8 version)
              ]
          , requestBody = RequestBodyLBS (encode req)
          }
  resp <- httpLbs reqHttp manager
  let code = statusCode (responseStatus resp)
      body = responseBody resp
  when (code /= 200) $
    ioError $
      userError $
        "POST /v1/messages: HTTP " ++ show code ++ " " ++ show (LBS.toStrict body)
  val <- case eitherDecode body of
    Left err -> ioError $ userError $ "JSON decode: " ++ err
    Right (v :: Value) -> pure v
  let fixed = patchThinkingSignatures (patchProxyNullArrays val)
  case fromJSON fixed of
    Error err -> ioError $ userError $ "MessageResponse: " ++ err
    Success msg -> pure msg

-- | Gateways may send @null@ where Anthropic sends @[]@ for vector-shaped fields.
patchProxyNullArrays :: Value -> Value
patchProxyNullArrays v = case v of
  Object o ->
    let o1 = KM.map patchProxyNullArrays o
        o2 = patchMessageResponseContent o1
        o3 = patchToolReferences o2
        o4 = patchCodeExecutionResultContent o3
     in Object o4
  Array a -> Array $ Vector.map patchProxyNullArrays a
  _ -> v
  where
    patchMessageResponseContent o =
      case (KM.lookup "content" o, KM.lookup "usage" o) of
        (Just Null, Just _) -> KM.insert "content" (Array Vector.empty) o
        _ -> o
    patchToolReferences o =
      case KM.lookup "tool_references" o of
        Just Null -> KM.insert "tool_references" (Array Vector.empty) o
        _ -> o
    patchCodeExecutionResultContent o
      | KM.member "stdout" o && KM.member "stderr" o && KM.member "return_code" o
      , Just Null <- KM.lookup "content" o =
          KM.insert "content" (Array Vector.empty) o
      | otherwise = o

-- | Proxies sometimes omit @"signature"@ on @type: "thinking"@ blocks.
patchThinkingSignatures :: Value -> Value
patchThinkingSignatures v = case v of
  Object o ->
    let oRecursed = KM.map patchThinkingSignatures o
     in case (KM.lookup "type" oRecursed, KM.lookup "signature" oRecursed) of
          (Just (String "thinking"), Nothing) ->
            Object $ KM.insert "signature" (String "") oRecursed
          (Just (String "thinking"), Just Null) ->
            Object $ KM.insert "signature" (String "") oRecursed
          _ -> Object oRecursed
  Array a -> Array $ Vector.map patchThinkingSignatures a
  _ -> v

stripTrailingSlash :: Text -> Text
stripTrailingSlash t =
  case Text.unsnoc t of
    Nothing -> t
    Just (rest, c) -> if c == '/' then stripTrailingSlash rest else t

nowMs :: IO Int64
nowMs = round . (* 1000) <$> getPOSIXTime

toNaturalMax1 :: Int -> Natural
toNaturalMax1 = fromIntegral . max 1

resolveModelId :: Model -> Text
resolveModelId m = if Text.null (mId m) then defaultAnthropicModelId else mId m

-- ─── Message conversion ────────────────────────────────────────────────────

piMessageToClaude :: Message -> Either Text CM.Message
piMessageToClaude (MsgUser UserMessage {umContent = cs}) =
  Right
    CM.Message
      { CM.role = CM.User
      , CM.content = Vector.fromList (map userContentToClaude cs)
      , CM.cache_control = Nothing
      }
piMessageToClaude (MsgAssistant AssistantMessage {amContent = cs}) =
  Right
    CM.Message
      { CM.role = CM.Assistant
      , CM.content = Vector.fromList (concatMap assistantContentToClaude cs)
      , CM.cache_control = Nothing
      }
piMessageToClaude (MsgToolResult ToolResultMessage {trmToolCallId = tid, trmContent = cs, trmIsError = err}) =
  Right
    CM.Message
      { CM.role = CM.User
      , CM.content =
          Vector.singleton
            CM.Content_Tool_Result
              { CM.tool_use_id = tid
              , CM.content = Just (toolResultText cs)
              , CM.is_error = Just err
              }
      , CM.cache_control = Nothing
      }

userContentToClaude :: UserContent -> CM.Content
userContentToClaude = \case
  UCText tc ->
    CM.Content_Text {CM.text = tcText tc, CM.cache_control = Nothing}
  UCImage (ImageContent d mt) ->
    CM.Content_Text {CM.text = "Image (" <> mt <> "): " <> d, CM.cache_control = Nothing}

assistantContentToClaude :: AssistantContent -> [CM.Content]
assistantContentToClaude = \case
  ACText (TextContent t _) ->
    [CM.Content_Text {CM.text = t, CM.cache_control = Nothing}]
  ACThinking (ThinkingContent t s _) ->
    [CM.Content_Thinking {CM.thinking = t, CM.signature = fromMaybe "" s}]
  ACToolCall ToolCall {tcId = i, tcName = n, tcArguments = a} ->
    [CM.Content_Tool_Use {CM.id = i, CM.name = n, CM.input = a, CM.caller = Nothing}]

toolResultText :: [ToolResultContent] -> Text
toolResultText = Text.concat . map blockText
  where
    blockText (TRCText (TextContent t _)) = t
    blockText (TRCImage _) = "[image]"

-- ─── Response conversion ───────────────────────────────────────────────────

messageResponseToAssistant :: Int64 -> Text -> Text -> Model -> CM.MessageResponse -> Either Text AssistantMessage
messageResponseToAssistant ts api provider model resp = do
  let rawVal = toJSON resp
      respId = case rawVal of
        Object o -> case KM.lookup "id" o of
          Just (String s) -> Just s
          _ -> Nothing
        _ -> Nothing
      usage = extractUsage rawVal
  case resp of
    CM.MessageResponse _ _ _ respContent _ respStop _ _ _ -> do
      content <- traverse contentBlockToAssistant (Vector.toList respContent)
      sr <- mapStopReason respStop
      pure
        AssistantMessage
          { amContent = content
          , amApi = api
          , amProvider = provider
          , amModel = mId model
          , amResponseId = respId
          , amUsage = usage
          , amStopReason = sr
          , amErrorMessage = Nothing
          , amTimestamp = ts
          }

contentBlockToAssistant :: CM.ContentBlock -> Either Text AssistantContent
contentBlockToAssistant = \case
  CM.ContentBlock_Text {CM.text = t} ->
    Right (ACText (TextContent t Nothing))
  CM.ContentBlock_Thinking {CM.thinking = t} ->
    Right (ACThinking (ThinkingContent t Nothing Nothing))
  CM.ContentBlock_Tool_Use {CM.id = i, CM.name = n, CM.input = a} ->
    Right (ACToolCall (ToolCall i n a Nothing))
  CM.ContentBlock_Redacted_Thinking {} ->
    Right (ACThinking (ThinkingContent "[redacted thinking]" Nothing (Just True)))
  CM.ContentBlock_Server_Tool_Use {CM.name = n} ->
    Left ("Unsupported server tool block: " <> n)
  CM.ContentBlock_Tool_Search_Tool_Result {} ->
    Left "Unexpected tool_search_tool_result block"
  CM.ContentBlock_Code_Execution_Tool_Result {} ->
    Left "Unexpected code_execution_tool_result block"
  CM.ContentBlock_Unknown {CM.type_ = ty} ->
    Left ("Unknown assistant content block type: " <> ty)

mapStopReason :: Maybe CM.StopReason -> Either Text StopReason
mapStopReason Nothing = Right StopEndTurn
mapStopReason (Just CM.End_Turn) = Right StopEndTurn
mapStopReason (Just CM.Tool_Use) = Right StopToolUse
mapStopReason (Just CM.Max_Tokens) = Right StopMaxTokens
mapStopReason (Just CM.Model_Context_Window_Exceeded) = Right StopMaxTokens
mapStopReason (Just CM.Stop_Sequence) = Right StopEndTurn
mapStopReason (Just CM.Refusal) = Right StopError

-- ─── Usage extraction ──────────────────────────────────────────────────────

extractUsage :: Value -> Usage
extractUsage (Object o) = case KM.lookup "usage" o of
  Just (Object u) ->
    Usage
      { uInput = fromMaybe 0 (parseInt =<< KM.lookup "input_tokens" u)
      , uOutput = fromMaybe 0 (parseInt =<< KM.lookup "output_tokens" u)
      , uCacheRead = fromMaybe 0 (parseInt =<< KM.lookup "cache_read_input_tokens" u)
      , uCacheWrite = fromMaybe 0 (parseInt =<< KM.lookup "cache_creation_input_tokens" u)
      , uTotalTokens = fromMaybe 0 (parseInt =<< KM.lookup "total_tokens" u)
      , uCost = Cost 0 0 0 0 0
      }
  _ -> defaultUsage
extractUsage _ = defaultUsage

parseInt :: Value -> Maybe Int
parseInt (Number n) = toBoundedInteger n
parseInt _ = Nothing
