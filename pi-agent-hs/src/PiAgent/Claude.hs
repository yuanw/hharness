{-# LANGUAGE DuplicateRecordFields #-}

-- | Bridge from @pi-agent-hs@ to Mercury\'s @claude@ package
-- (<https://github.com/MercuryTechnologies/claude>).
--
-- Implements 'StreamFn' via the blocking Messages API (@createMessage@): one
-- @EvStart@ with the completed assistant turn, then end-of-stream. That is
-- enough for the agent loop (tools, steering, follow-ups) and mirrors the
-- control flow described in
-- <https://ampcode.com/notes/how-to-build-an-agent>.
module PiAgent.Claude
  ( claudeStreamFn
  , defaultClaudeModelId
  ) where

import Control.Concurrent.Async (async)
import Control.Exception (SomeException, try)
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Numeric.Natural (Natural)

import qualified Claude.V1 as V1
import qualified Claude.V1.Messages as CM
import qualified Claude.V1.Tool as Tool
import qualified Data.Text as Text
import qualified Data.Vector as Vector

import PiAgent.AgentLoop (StreamFn)
import PiAgent.Stream (endStream, newEventStream, pushEvent)
import PiAgent.Types

-- | Model id aligned with the upstream @claude@ package examples.
defaultClaudeModelId :: Text
defaultClaudeModelId = "claude-sonnet-4-5-20250929"

-- | Build a 'StreamFn' from 'V1.Methods' ('V1.makeMethods').
--
-- The caller\'s API key is the one used to create @Methods@; @soApiKey@ in
-- 'StreamOptions' is ignored for now.
claudeStreamFn :: V1.Methods -> StreamFn
claudeStreamFn methods model llmCtx opts = do
  es <- newEventStream
  _ <- async $ do
    ts <- nowMs
    let onErr msg = do
          let p =
                PartialAssistantMessage
                  { pamBlocks = []
                  , pamStopReason = StopError
                  , pamErrorMsg = Just msg
                  , pamTimestamp = ts
                  }
          pushEvent es (EvError p (Just msg))
          endStream es p
    r <- try @SomeException $ do
      msgs <- case traverse piMessageToClaude (lcMessages llmCtx) of
        Left err -> fail (Text.unpack err)
        Right ok -> pure ok
      let tools = case lcTools llmCtx of
            Nothing -> Nothing
            Just defs ->
              Just $ Vector.fromList $ map llmToolToDefinition defs
          maxTok = fromMaybe 8192 (soMaxTokens opts)
          req =
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
      let V1.Methods{V1.createMessage = createMessage} = methods
      createMessage req
    case r of
      Left e -> onErr (Text.pack (show e))
      Right resp ->
        case messageResponseToPartial ts resp of
          Left err -> onErr err
          Right p -> do
            pushEvent es (EvStart p)
            endStream es p
  pure es

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
  UserMessage{umContent = cs} ->
    Right
      CM.Message
        { CM.role = CM.User
        , CM.content = Vector.fromList (map userContentBlock cs)
        , CM.cache_control = Nothing
        }
  AssistantMessage{amBlocks = bs} ->
    Right
      CM.Message
        { CM.role = CM.Assistant
        , CM.content = Vector.fromList (concatMap assistantBlockToContents bs)
        , CM.cache_control = Nothing
        }
  ToolResultMessage{trmToolCallId = tid, trmContent = cs, trmIsError = err} ->
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
    CM.Content_Text{CM.text = tcText tc, CM.cache_control = Nothing}
  BlockImage (ImageContent u mt) ->
    CM.Content_Text
      { CM.text = "Image (" <> mt <> "): " <> u
      , CM.cache_control = Nothing
      }

assistantBlockToContents :: AssistantBlock -> [CM.Content]
assistantBlockToContents = \case
  ABText t ->
    [CM.Content_Text{CM.text = t, CM.cache_control = Nothing}]
  ABThinking t ->
    [CM.Content_Thinking{CM.thinking = t, CM.signature = ""}]
  ABToolCall ToolCall{tcId = i, tcName = n, tcArguments = a} ->
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
  CM.ContentBlock_Text{CM.text = t} -> Right (ABText t)
  CM.ContentBlock_Thinking{CM.thinking = t} -> Right (ABThinking t)
  CM.ContentBlock_Tool_Use{CM.id = i, CM.name = n, CM.input = a} ->
    Right (ABToolCall ToolCall{tcId = i, tcName = n, tcArguments = a})
  CM.ContentBlock_Redacted_Thinking{} ->
    Right (ABThinking "[redacted thinking]")
  CM.ContentBlock_Server_Tool_Use{CM.name = n} ->
    Left ("Unsupported server tool block in assistant output: " <> n)
  CM.ContentBlock_Tool_Search_Tool_Result{} ->
    Left "Unexpected tool_search_tool_result block in assistant output"
  CM.ContentBlock_Code_Execution_Tool_Result{} ->
    Left "Unexpected code_execution_tool_result block in assistant output"
  CM.ContentBlock_Unknown{CM.type_ = ty} ->
    Left ("Unknown assistant content block type: " <> ty)

mapStopReason :: Maybe CM.StopReason -> Either Text StopReason
mapStopReason Nothing = Right StopEndTurn
mapStopReason (Just CM.End_Turn) = Right StopEndTurn
mapStopReason (Just CM.Tool_Use) = Right StopToolUse
mapStopReason (Just CM.Max_Tokens) = Right StopMaxTokens
mapStopReason (Just CM.Model_Context_Window_Exceeded) = Right StopMaxTokens
mapStopReason (Just CM.Stop_Sequence) = Right StopEndTurn
mapStopReason (Just CM.Refusal) = Right StopError
