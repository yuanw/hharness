{- | Wrap a `StreamFn` so that every request and every response event is
written to a JSONL file.

This is invaluable for end-to-end debugging and for generating golden
test fixtures from real API interactions.
-}
module HHAi.Provider.Logging (
  withRequestResponseLogging,
  LogTag (..),
  LogEntry (..),
) where

import Control.Concurrent.Async (async)
import Control.Exception (SomeException, try)
import Control.Monad (unless)
import Data.Aeson (ToJSON, Value, encode, object, toJSON, (.=))
import Data.ByteString.Lazy qualified as BSL
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8)
import Data.Text.IO qualified as TIO
import Data.Time.Clock.POSIX (getPOSIXTime)
import GHC.Generics (Generic)
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory)

import HHAi.Stream (EventStream, endStream, getResult, newEventStream, nextEvent, pushEvent)
import HHAi.Types

-- ─── Log format ──────────────────────────────────────────────────────────────

data LogTag = LogRequest | LogResponse | LogError
  deriving (Show, Generic)

instance ToJSON LogTag where
  toJSON LogRequest = "request"
  toJSON LogResponse = "response"
  toJSON LogError = "error"

data LogEntry = LogEntry
  { leTag :: LogTag
  , leTimestamp :: Int64
  , leModelId :: Text
  , lePayload :: Value
  }
  deriving (Show, Generic)

instance ToJSON LogEntry where
  toJSON e =
    object
      [ "tag" .= leTag e
      , "timestamp" .= leTimestamp e
      , "modelId" .= leModelId e
      , "payload" .= lePayload e
      ]

-- ─── Public API ────────────────────────────────────────────────────────────

{- | Wrap a base `StreamFn` with JSONL request/response logging.

Every outgoing `Context` is logged as a `LogRequest` entry.
Every streaming event and the final result are logged as `LogResponse`
or `LogError` entries.

The log is append-only (opened, written, flushed, closed per entry).
-}
withRequestResponseLogging :: FilePath -> StreamFn -> StreamFn
withRequestResponseLogging logPath baseFn model ctx opts = do
  t0 <- nowMs
  ensureLogDir logPath
  -- Log the outgoing request
  appendJsonl logPath $
    LogEntry
      { leTag = LogRequest
      , leTimestamp = t0
      , leModelId = mId model
      , lePayload = contextToValue ctx
      }
  -- Run the real provider
  es <- baseFn model ctx opts
  -- Fork a tee thread
  es' <- newEventStream
  _ <- async $ do
    let loop = do
          mev <- nextEvent es
          case mev of
            Nothing -> do
              res <- try @SomeException (getResult es)
              t1 <- nowMs
              case res of
                Right msg -> do
                  appendJsonl logPath $
                    LogEntry
                      { leTag = LogResponse
                      , leTimestamp = t1
                      , leModelId = mId model
                      , lePayload = object ["stopReason" .= show (amStopReason msg), "contentCount" .= length (amContent msg)]
                      }
                  endStream es' msg
                Left e -> do
                  appendJsonl logPath $
                    LogEntry
                      { leTag = LogError
                      , leTimestamp = t1
                      , leModelId = mId model
                      , lePayload = toJSON (Text.pack $ show e)
                      }
                  endStream es' (error $ show e)
            Just ev -> do
              t <- nowMs
              appendJsonl logPath $
                LogEntry
                  { leTag = LogResponse
                  , leTimestamp = t
                  , leModelId = mId model
                  , lePayload = eventToValue ev
                  }
              pushEvent es' ev
              loop
    loop
  pure es'

-- ─── JSON helpers ──────────────────────────────────────────────────────────

contextToValue :: Context -> Value
contextToValue ctx =
  object
    [ "systemPrompt" .= cSystemPrompt ctx
    , "messageCount" .= length (cMessages ctx)
    , "messages" .= map (toJSON . messageRole) (cMessages ctx)
    , "toolCount" .= maybe 0 length (cTools ctx)
    ]

eventToValue :: AssistantMessageEvent -> Value
eventToValue ev = case ev of
  EvStart _ -> object ["event" .= ("start" :: Text)]
  EvTextStart _ _ -> object ["event" .= ("text_start" :: Text)]
  EvTextDelta _ txt _ -> object ["event" .= ("text_delta" :: Text), "text" .= txt]
  EvTextEnd _ txt _ -> object ["event" .= ("text_end" :: Text), "text" .= txt]
  EvThinkingStart _ _ -> object ["event" .= ("thinking_start" :: Text)]
  EvThinkingDelta _ txt _ -> object ["event" .= ("thinking_delta" :: Text), "text" .= txt]
  EvThinkingEnd _ txt _ -> object ["event" .= ("thinking_end" :: Text), "text" .= txt]
  EvToolCallStart _ _ -> object ["event" .= ("tool_call_start" :: Text)]
  EvToolCallDelta _ txt _ -> object ["event" .= ("tool_call_delta" :: Text), "text" .= txt]
  EvToolCallEnd _ tc _ ->
    object
      [ "event" .= ("tool_call_end" :: Text)
      , "toolCallId" .= tcId tc
      , "toolName" .= tcName tc
      ]
  EvDone sr msg -> object ["event" .= ("done" :: Text), "stopReason" .= show sr, "message" .= object ["stopReason" .= show (amStopReason msg), "contentCount" .= length (amContent msg)]]
  EvError sr txt msg ->
    object
      [ "event" .= ("error" :: Text)
      , "stopReason" .= show sr
      , "errorText" .= txt
      , "message" .= object ["stopReason" .= show (amStopReason msg), "contentCount" .= length (amContent msg)]
      ]

-- ─── File I/O ──────────────────────────────────────────────────────────────

appendJsonl :: (ToJSON a) => FilePath -> a -> IO ()
appendJsonl path v = do
  let line = decodeUtf8 $ BSL.toStrict $ encode v
  TIO.appendFile path (line <> "\n")

ensureLogDir :: FilePath -> IO ()
ensureLogDir path = createDirectoryIfMissing True (takeDirectory path)

nowMs :: IO Int64
nowMs = round . (* 1000) <$> getPOSIXTime
