{- | Faux / testing provider.

Returns canned assistant messages without calling any external API.
Useful for unit-testing the agent loop without API keys.
-}
module HHAi.Provider.Faux (
  fauxStreamFn,
  fauxApiProvider,
  registerFaux,
) where

import Control.Concurrent.Async (async)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Time.Clock.POSIX (getPOSIXTime)

import HHAi.Registry (ApiProvider (..), ApiRegistry, registerApiProvider)
import HHAi.Stream (endStream, newEventStream, pushEvent)
import HHAi.Types

-- ─── Public API ────────────────────────────────────────────────────────────

{- | A 'StreamFn' that immediately yields a single text response.

The returned stream emits one 'EvStart' / 'EvText*' chain and then
ends with the final 'AssistantMessage'.
-}
fauxStreamFn :: Text -> StreamFn
fauxStreamFn responseText _model _ctx _opts = do
  es <- newEventStream
  _ <- async $ do
    ts <- nowMs
    let blocks = [ACText (TextContent responseText Nothing)]
        final =
          AssistantMessage
            { amContent = blocks
            , amApi = "faux"
            , amProvider = "faux"
            , amModel = ""
            , amResponseId = Nothing
            , amUsage = defaultUsage
            , amStopReason = StopEndTurn
            , amErrorMessage = Nothing
            , amTimestamp = ts
            }
        partial =
          PartialAssistantMessage
            { pamContent = blocks
            , pamStopReason = StopEndTurn
            , pamErrorMessage = Nothing
            , pamTimestamp = ts
            }
    pushEvent es (EvStart partial)
    pushEvent es (EvTextStart 0 partial)
    pushEvent es (EvTextDelta 0 responseText partial)
    pushEvent es (EvTextEnd 0 responseText partial)
    pushEvent es (EvDone StopEndTurn final)
    endStream es final
  pure es

-- | Provider record that always returns the given canned text.
fauxApiProvider :: Text -> ApiProvider
fauxApiProvider responseText =
  ApiProvider
    { apApi = "faux"
    , apStream = fauxStreamFn responseText
    , apStreamSimple = \model ctx sso -> fauxStreamFn responseText model ctx (simpleToStreamOpts sso)
    }

-- | Register a faux provider that returns @responseText@.
registerFaux :: ApiRegistry -> Text -> IO ()
registerFaux registry responseText =
  registerApiProvider registry (fauxApiProvider responseText)

-- ─── Internals ─────────────────────────────────────────────────────────────

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
