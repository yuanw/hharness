{- | Minimal CLI for end-to-end testing against local or remote LLM APIs.

Example usage with a local Ollama model:

  @
  export HHARNESS_LOG=./debug.jsonl
  cabal run hharness-cli -- --model qwen2.5:14b --message "What is 2 + 2?"
  @

The tool writes every request and every streamed response event to the
JSONL log so you can inspect the full conversation afterwards.
-}
module Main where

import Control.Monad (when)
import Data.Int (Int64)
import Data.List (find)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Data.Time.Clock.POSIX (getPOSIXTime)
import Options.Applicative
import System.Environment (lookupEnv)

import HHAi.Models.Json (loadModelById, loadUserModels)
import HHAi.Provider.Logging (withRequestResponseLogging)
import HHAi.Provider.OpenAI (registerOpenAI)
import HHAi.Registry
import HHAi.Stream (endStream, foldStream, newEventStream, pushEvent)
import HHAi.Types

-- ═════════════════════════════════════════════════════════════════════════════
--  CLI options
-- ═════════════════════════════════════════════════════════════════════════════

data CliOpts = CliOpts
  { cliModelId :: String
  , cliMessage :: String
  , cliLogFile :: Maybe String
  , cliSystem :: Maybe String
  }

optsParser :: Parser CliOpts
optsParser =
  CliOpts
    <$> strOption
      ( long "model"
          <> short 'm'
          <> metavar "MODEL_ID"
          <> help "Model identifier (from ~/.pi/agent/models.json or built-in)"
          <> value "gpt-4o"
          <> showDefault
      )
    <*> strOption
      ( long "message"
          <> short 'M'
          <> metavar "TEXT"
          <> help "User message to send"
      )
    <*> optional
      ( strOption
          ( long "log-file"
              <> short 'l'
              <> metavar "PATH"
              <> help "JSONL request/response log path"
          )
      )
    <*> optional
      ( strOption
          ( long "system"
              <> short 's'
              <> metavar "PROMPT"
              <> help "System prompt override"
          )
      )

parserInfo :: ParserInfo CliOpts
parserInfo =
  info
    (optsParser <**> helper)
    ( fullDesc
        <> progDesc "Send a single user message to an LLM and print the response"
        <> header "hharness-cli: minimal LLM CLI for end-to-end testing"
    )

-- ═════════════════════════════════════════════════════════════════════════════
--  Main
-- ═════════════════════════════════════════════════════════════════════════════

main :: IO ()
main = do
  opts <- execParser parserInfo
  let mid = Text.pack (cliModelId opts)
      userMsg = Text.pack (cliMessage opts)
  maybeModel <- loadModelById mid
  model <- case maybeModel of
    Just m -> pure m
    Nothing -> do
      TIO.putStrLn $ "Model '" <> mid <> "' not found. Available models:"
      models <- loadUserModels
      mapM_ (TIO.putStrLn . ("  - " <>) . mId) models
      error "Unknown model"

  -- Register providers
  registry <- newRegistry
  registerOpenAI registry

  provider <- fromMaybe (error ("No provider registered for API: " ++ Text.unpack (mApi model))) <$> getApiProvider registry (mApi model)

  -- Resolve log file path
  envLog <- lookupEnv "HHARNESS_LOG"
  let logPath = fromMaybe (fromMaybe "" (cliLogFile opts)) envLog
      useLog = not (null logPath)

  -- Wrap with logging if requested
  let streamFn =
        if useLog
          then withRequestResponseLogging logPath (apStream provider)
          else apStream provider

  -- Build context
  ts <- nowMs
  let ctx =
        Context
          { cSystemPrompt = if null (cliSystem opts) then Nothing else Just (Text.pack $ fromMaybe "" (cliSystem opts))
          , cMessages = [MsgUser $ UserMessage [UCText $ TextContent userMsg Nothing] ts]
          , cTools = Nothing
          }
      sopts = defaultStreamOptions {soApiKey = Nothing, soMaxTokens = Just 2048}

  -- Stream and print
  es <- streamFn model ctx sopts
  final <- foldStream es $ \case
    EvTextDelta _ txt _ -> TIO.putStr txt
    EvDone _ _ -> TIO.putStrLn ""
    _ -> pure ()

  TIO.putStrLn $ "\n[Done] stopReason=" <> Text.pack (show $ amStopReason final)
  when useLog $ putStrLn $ "[log] " ++ logPath

-- ─── Utilities ─────────────────────────────────────────────────────────────

nowMs :: IO Int64
nowMs = round . (* 1000) <$> getPOSIXTime
