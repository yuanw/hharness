{-# LANGUAGE OverloadedStrings #-}

module OpenAIProviderSpec where

import Control.Monad (forM_)
import Data.Aeson (Value (..), encode, object, (.=))
import Data.Aeson.Key (fromText)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.IORef
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Test.Hspec

import HHAi.Provider.OpenAI
import HHAi.Stream (EventStream, endStream, foldStream, newEventStream)
import HHAi.Types

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. Tool argument serialization
-- ═════════════════════════════════════════════════════════════════════════════

spec_toolCallToOpenAI :: Spec
spec_toolCallToOpenAI = describe "toolCallToOpenAI" $ do
  it "serialises arguments as a JSON string, not an object" $ do
    let tc =
          ToolCall
            { tcId = "call_123"
            , tcName = "read_file"
            , tcArguments = object [("path", String "/etc/hosts")]
            , tcThoughtSignature = Nothing
            }
        val = toolCallToOpenAI tc
    -- The "arguments" field inside "function" must be a String
    case val of
      Object obj -> do
        case lookupKey "function" obj of
          Just (Object fn) -> case lookupKey "arguments" fn of
            Just (String argStr) -> do
              argStr `shouldBe` "{\"path\":\"/etc/hosts\"}"
            _ -> expectationFailure "arguments was not a String"
          _ -> expectationFailure "function key missing or not an object"
      _ -> expectationFailure "toolCallToOpenAI did not return an Object"

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. SSE result accumulation (<|> fix)
-- ═════════════════════════════════════════════════════════════════════════════

spec_processSse :: Spec
spec_processSse = describe "processSse" $ do
  it "keeps the first Just result and does not discard it" $ do
    let chunks =
          [ "data: {\"x\":1}\n"
          , "data: {\"y\":2}\n"
          ]
        handler val = pure $ case val of
          Object obj | Just (Number 1) <- lookupKey "x" obj -> Nothing
          Object obj | Just (Number 2) <- lookupKey "y" obj -> Just dummyMsg
          _ -> Nothing
    br <- makeBodyReader chunks
    result <- processSse br handler
    result `shouldBe` Just dummyMsg

  it "returns Nothing when the handler never returns Just" $ do
    let chunks = ["data: {\"x\":1}\n"]
        handler _ = pure Nothing
    br <- makeBodyReader chunks
    result <- processSse br handler
    result `shouldBe` Nothing

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. processCompletionDelta accumulates tool calls across chunks
-- ═════════════════════════════════════════════════════════════════════════════

spec_processCompletionDelta :: Spec
spec_processCompletionDelta = describe "processCompletionDelta (persistent stateRef)" $ do
  it "accumulates tool call name+args across multiple SSE chunks" $ do
    es <- newEventStream
    stateRef <- newIORef emptyPartialState
    let model = Model "test" "test" "openai-completions" "test" "" False [] (Cost 0 0 0 0 0) 4096 2048 Nothing Nothing
        ts = 0
        -- Chunk 1: assistant starts + tool call with id+name but no args yet
        delta1 =
          KM.fromList
            [ ("role", String "assistant")
            ,
              ( "tool_calls"
              , Array $
                  Vector.fromList
                    [ object
                        [ "index" .= Number 0
                        , "id" .= String "call_abc"
                        , "function" .= object [("name", String "read_file")]
                        ]
                    ]
              )
            ]
        -- Chunk 2: tool call arguments arrive
        delta2 =
          KM.fromList
            [
              ( "tool_calls"
              , Array $
                  Vector.fromList
                    [ object
                        [ "index" .= Number 0
                        , "function" .= object [("arguments", String "{\\\"path\\\":\\\"/etc/hosts\\\"}")]
                        ]
                    ]
              )
            ]
        finish = Just StopToolUse

    _ <- processCompletionDelta es ts model stateRef delta1 Nothing
    mmsg <- processCompletionDelta es ts model stateRef delta2 finish

    -- Drain the event stream so the test doesn't block
    endStream es dummyMsg
    _ <- foldStream es (\_ -> pure ())

    mmsg `shouldSatisfy` isJust
    let msg = fromMaybe (error "expected Just msg") mmsg
    length (amContent msg) `shouldBe` 1
    case amContent msg of
      (ACToolCall tc : _) -> do
        tcName tc `shouldBe` "read_file"
        tcArguments tc `shouldBe` String "{\\\"path\\\":\\\"/etc/hosts\\\"}"
      _ -> expectationFailure "expected ACToolCall"

-- ─── Helpers ──────────────────────────────────────────────────────────────

dummyMsg :: AssistantMessage
dummyMsg =
  AssistantMessage
    { amContent = []
    , amApi = "test"
    , amProvider = "test"
    , amModel = "test"
    , amResponseId = Nothing
    , amUsage = defaultUsage
    , amStopReason = StopEndTurn
    , amErrorMessage = Nothing
    , amTimestamp = 0
    }

isJust :: Maybe a -> Bool
isJust (Just _) = True
isJust Nothing = False

lookupKey :: Text -> KM.KeyMap Value -> Maybe Value
lookupKey k = KM.lookup (fromText k)

makeBodyReader :: [LBS.ByteString] -> IO (IO ByteString)
makeBodyReader chunks = do
  ref <- newIORef (map LBS.toStrict chunks)
  pure $ do
    cs <- readIORef ref
    case cs of
      [] -> pure ""
      (x : xs) -> do
        writeIORef ref xs
        pure x
