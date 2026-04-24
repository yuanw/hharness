{-# LANGUAGE DuplicateRecordFields #-}

{- | Bridge from @hharness-agent@ to Mercury\'s @claude@ package
(<https://github.com/MercuryTechnologies/claude>).

Implements 'StreamFn' via the blocking Messages API (@\/v1\/messages@): one
@EvStart@ with the completed assistant turn, then end-of-stream.

Use 'claudeStreamFnCompat' when talking to proxies (e.g. Ollama) that omit the
@signature@ field on @thinking@ blocks — the stock @claude@ JSON parser
requires it, which would otherwise fail with @DecodeFailure@.
-}
module HHAgent.Claude (
  claudeStreamFn,
  claudeStreamFnCompat,
  defaultClaudeModelId,
) where

import Control.Concurrent.Async (async)
import Control.Exception (SomeException, try)
import Control.Monad (when)
import Data.Aeson (Result (..), Value (..), eitherDecode, encode, fromJSON)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as LBS
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Vector qualified as V
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
import Data.Text qualified as Text
import Data.Vector qualified as Vector

import HHAgent.AgentLoop (StreamFn)
import HHAgent.Stream (EventStream, endStream, newEventStream, pushEvent)
import HHAgent.Types

-- | Model id aligned with the upstream @claude@ package examples.
defaultClaudeModelId :: Text
defaultClaudeModelId = "claude-sonnet-4-5-20250929"

{- | Build a 'StreamFn' from 'V1.Methods' ('V1.makeMethods').

Uses the library\'s @createMessage@ as-is (strict Anthropic JSON). Prefer
'claudeStreamFnCompat' for local proxies that omit @signature@ on thinking blocks.
-}
claudeStreamFn :: V1.Methods -> StreamFn
claudeStreamFn methods model llmCtx opts = do
  es <- newEventStream
  _ <- async $ do
    ts <- nowMs
    let onErr = pushErr es ts
    r <- try @SomeException $ do
      req <- either (fail . Text.unpack) pure $ mkCreateMessage model llmCtx opts
      let V1.Methods {V1.createMessage = createMessage} = methods
      createMessage req
    finishStream es ts onErr r
  pure es

{- | Like 'claudeStreamFn' but POSTs via @http-client@ and patches the JSON
before decoding so proxies that omit @\"signature\"@ on @type: \"thinking\"@
blocks (Ollama, some gateways) still parse as 'CM.MessageResponse'.
-}
claudeStreamFnCompat :: Text -> Text -> Maybe Text -> StreamFn
claudeStreamFnCompat baseUrl apiKey anthropicVersion model llmCtx opts = do
  es <- newEventStream
  _ <- async $ do
    ts <- nowMs
    let onErr = pushErr es ts
    r <- try @SomeException $ do
      req <- either (fail . Text.unpack) pure $ mkCreateMessage model llmCtx opts
      createMessageCompat baseUrl apiKey anthropicVersion req
    finishStream es ts onErr r
  pure es

finishStream ::
  EventStream AssistantMessageEvent PartialAssistantMessage ->
  Int64 ->
  (Text -> IO ()) ->
  Either SomeException CM.MessageResponse ->
  IO ()
finishStream es ts onErr = \case
  Left e -> onErr (Text.pack (show e))
  Right resp ->
    case messageResponseToPartial ts resp of
      Left err -> onErr err
      Right p -> do
        pushEvent es (EvStart p)
        endStream es p

pushErr ::
  EventStream AssistantMessageEvent PartialAssistantMessage ->
  Int64 ->
  Text ->
  IO ()
pushErr es ts msg = do
  let p =
        PartialAssistantMessage
          { pamBlocks = []
          , pamStopReason = StopError
          , pamErrorMsg = Just msg
          , pamTimestamp = ts
          }
  pushEvent es (EvError p (Just msg))
  endStream es p

mkCreateMessage :: Model -> LLMContext -> StreamOptions -> Either Text CM.CreateMessage
mkCreateMessage model llmCtx opts = do
  msgs <- traverse piMessageToClaude (lcMessages llmCtx)
  let tools = case lcTools llmCtx of
        Nothing -> Nothing
        Just defs ->
          Just $ Vector.fromList $ map llmToolToDefinition defs
      maxTok = fromMaybe 8192 (soMaxTokens opts)
  pure
    CM._CreateMessage
      { CM.model = resolveModelId model
      , CM.messages = Vector.fromList msgs
      , CM.max_tokens = toNaturalMax1 maxTok
      , CM.system =
          if Text.null (lcSystemPrompt llmCtx)
            then Nothing
            else Just (CM.systemText (lcSystemPrompt llmCtx))
      , CM.temperature = soTemperature opts
      , CM.tools = tools
      }

-- | POST @\/v1\/messages@, patch JSON for lenient thinking blocks, decode.
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
        "POST /v1/messages: HTTP "
          ++ show code
          ++ " "
          ++ show (LBS.toStrict body)
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
  Array a -> Array $ V.map patchProxyNullArrays a
  _ -> v
  where
    -- 'MessageResponse' expects @content :: Vector ContentBlock@.
    patchMessageResponseContent o =
      case (KM.lookup "content" o, KM.lookup "usage" o) of
        (Just Null, Just _) -> KM.insert "content" (Array V.empty) o
        _ -> o
    -- 'ToolSearchResult' expects @tool_references :: Vector …@.
    patchToolReferences o =
      case KM.lookup "tool_references" o of
        Just Null -> KM.insert "tool_references" (Array V.empty) o
        _ -> o
    -- 'CodeExecutionResult' expects @content :: Vector Value@.
    patchCodeExecutionResultContent o
      | KM.member "stdout" o
          && KM.member "stderr" o
          && KM.member "return_code" o
      , Just Null <- KM.lookup "content" o =
          KM.insert "content" (Array V.empty) o
      | otherwise = o

-- | Proxies sometimes omit @\"signature\"@ on @type: \"thinking\"@ blocks.
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
  Array a -> Array $ V.map patchThinkingSignatures a
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
resolveModelId m =
  if Text.null (modelId m)
    then defaultClaudeModelId
    else modelId m

llmToolToDefinition :: LLMTool -> Tool.ToolDefinition
llmToolToDefinition t =
  Tool.inlineTool $
    Tool.functionTool
      (ltName t)
      (Just (ltDescription t))
      (ltSchema t)

piMessageToClaude :: Message -> Either Text CM.Message
piMessageToClaude = \case
  UserMessage {umContent = cs} ->
    Right
      CM.Message
        { CM.role = CM.User
        , CM.content = Vector.fromList (map userContentBlock cs)
        , CM.cache_control = Nothing
        }
  AssistantMessage {amBlocks = bs} ->
    Right
      CM.Message
        { CM.role = CM.Assistant
        , CM.content = Vector.fromList (concatMap assistantBlockToContents bs)
        , CM.cache_control = Nothing
        }
  ToolResultMessage {trmToolCallId = tid, trmContent = cs, trmIsError = err} ->
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

userContentBlock :: ContentBlock -> CM.Content
userContentBlock = \case
  BlockText tc ->
    CM.Content_Text {CM.text = tcText tc, CM.cache_control = Nothing}
  BlockImage (ImageContent u mt) ->
    CM.Content_Text
      { CM.text = "Image (" <> mt <> "): " <> u
      , CM.cache_control = Nothing
      }

assistantBlockToContents :: AssistantBlock -> [CM.Content]
assistantBlockToContents = \case
  ABText t ->
    [CM.Content_Text {CM.text = t, CM.cache_control = Nothing}]
  ABThinking t ->
    [CM.Content_Thinking {CM.thinking = t, CM.signature = ""}]
  ABToolCall ToolCall {tcId = i, tcName = n, tcArguments = a} ->
    [ CM.Content_Tool_Use
        { CM.id = i
        , CM.name = n
        , CM.input = a
        , CM.caller = Nothing
        }
    ]

toolResultText :: [ContentBlock] -> Text
toolResultText = Text.concat . map blockText
  where
    blockText (BlockText tc) = tcText tc
    blockText (BlockImage _) = "[image]"

messageResponseToPartial :: Int64 -> CM.MessageResponse -> Either Text PartialAssistantMessage
messageResponseToPartial ts (CM.MessageResponse _ _ _ respContent _ respStop _ _ _) = do
  blocks <- traverse contentBlockToAssistant (Vector.toList respContent)
  sr <- mapStopReason respStop
  pure
    PartialAssistantMessage
      { pamBlocks = blocks
      , pamStopReason = sr
      , pamErrorMsg = Nothing
      , pamTimestamp = ts
      }

contentBlockToAssistant :: CM.ContentBlock -> Either Text AssistantBlock
contentBlockToAssistant = \case
  CM.ContentBlock_Text {CM.text = t} -> Right (ABText t)
  CM.ContentBlock_Thinking {CM.thinking = t} -> Right (ABThinking t)
  CM.ContentBlock_Tool_Use {CM.id = i, CM.name = n, CM.input = a} ->
    Right (ABToolCall ToolCall {tcId = i, tcName = n, tcArguments = a})
  CM.ContentBlock_Redacted_Thinking {} ->
    Right (ABThinking "[redacted thinking]")
  CM.ContentBlock_Server_Tool_Use {CM.name = n} ->
    Left ("Unsupported server tool block in assistant output: " <> n)
  CM.ContentBlock_Tool_Search_Tool_Result {} ->
    Left "Unexpected tool_search_tool_result block in assistant output"
  CM.ContentBlock_Code_Execution_Tool_Result {} ->
    Left "Unexpected code_execution_tool_result block in assistant output"
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
