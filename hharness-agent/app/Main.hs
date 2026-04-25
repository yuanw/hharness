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

import Control.Exception (IOException, try)
import Control.Monad (when)
import Data.IORef
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Data.Time.Clock.POSIX (getPOSIXTime)
import Options.Applicative
import System.Environment (lookupEnv)
import System.IO (hFlush, stdout)

import HHAi.Models.Json (loadModelById, loadUserModels)
import HHAi.Provider.Logging (withRequestResponseLogging)
import HHAi.Provider.OpenAI (registerOpenAI)
import HHAi.Registry
import HHAi.Stream (EventStream, foldStream)
import HHAi.Types

-- ═════════════════════════════════════════════════════════════════════════════
--  CLI options
-- ═════════════════════════════════════════════════════════════════════════════

data CliOpts = CliOpts
  { cliModelId :: String
  , cliMessage :: String
  , cliLogFile :: Maybe String
  , cliSystem :: Maybe String
  , cliInteractive :: Bool
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
          <> help "User message to send (required in single-turn mode)"
          <> value ""
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
    <*> switch
      ( long "interactive"
          <> short 'i'
          <> help "Interactive multi-turn REPL mode"
      )

parserInfo :: ParserInfo CliOpts
parserInfo =
  info
    (optsParser <**> helper)
    ( fullDesc
        <> progDesc "Send user messages to an LLM. Use --interactive for multi-turn REPL."
        <> header "hharness-cli: minimal LLM CLI for end-to-end testing"
    )

-- ═════════════════════════════════════════════════════════════════════════════
--  Main
-- ═════════════════════════════════════════════════════════════════════════════

main :: IO ()
main = do
  opts <- execParser parserInfo
  let mid = Text.pack (cliModelId opts)
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
      streamFnBase = apStream provider
      streamFn = if useLog then withRequestResponseLogging logPath streamFnBase else streamFnBase

  if cliInteractive opts
    then runInteractive model streamFn opts logPath useLog
    else runSingle model streamFn opts logPath useLog

-- ─── Single-turn mode ─────────────────────────────────────────────────────

runSingle :: Model -> (Model -> Context -> StreamOptions -> IO (EventStream AssistantMessageEvent AssistantMessage)) -> CliOpts -> String -> Bool -> IO ()
runSingle model streamFn opts logPath useLog = do
  when (null (cliMessage opts)) $ error "--message is required in single-turn mode"
  let userMsg = Text.pack (cliMessage opts)
  ts <- nowMs
  let ctx =
        Context
          { cSystemPrompt = sysPrompt opts
          , cMessages = [MsgUser $ UserMessage [UCText $ TextContent userMsg Nothing] ts]
          , cTools = Nothing
          }
      sopts = defaultStreamOptions {soApiKey = Nothing, soMaxTokens = Just 2048}

  es <- streamFn model ctx sopts
  final <- foldStream es $ \case
    EvTextDelta _ txt _ -> TIO.putStr txt
    EvDone _ _ -> TIO.putStrLn ""
    _ -> pure ()

  TIO.putStrLn $ "\n[Done] stopReason=" <> Text.pack (show $ amStopReason final)
  when useLog $ putStrLn $ "[log] " ++ logPath

-- ─── Interactive multi-turn mode ────────────────────────────────────────────

runInteractive :: Model -> (Model -> Context -> StreamOptions -> IO (EventStream AssistantMessageEvent AssistantMessage)) -> CliOpts -> String -> Bool -> IO ()
runInteractive model streamFn opts logPath useLog = do
  ctxRef <-
    newIORef $
      Context
        { cSystemPrompt = sysPrompt opts
        , cMessages = []
        , cTools = Nothing
        }

  let sopts = defaultStreamOptions {soApiKey = Nothing, soMaxTokens = Just 2048}

  when useLog $ putStrLn $ "[logging to " ++ logPath ++ "]"
  TIO.putStrLn "Interactive mode. Type /quit, /exit, or /q to leave."

  let loop = do
        TIO.putStr "> "
        hFlush stdout
        mLine <- try TIO.getLine :: IO (Either IOException Text)
        case mLine of
          Left _ -> pure () -- EOF
          Right line
            | Text.strip line `elem` ["/quit", "/exit", "/q"] -> pure ()
            | Text.null (Text.strip line) -> loop
            | otherwise -> do
                ts <- nowMs
                modifyIORef' ctxRef $ \c ->
                  c
                    { cMessages = cMessages c <> [MsgUser $ UserMessage [UCText $ TextContent line Nothing] ts]
                    }
                ctx <- readIORef ctxRef
                es <- streamFn model ctx sopts
                final <- foldStream es $ \case
                  EvTextDelta _ txt _ -> TIO.putStr txt
                  EvDone _ _ -> TIO.putStrLn ""
                  _ -> pure ()

                let finalMsg = MsgAssistant final
                modifyIORef' ctxRef $ \c -> c {cMessages = cMessages c <> [finalMsg]}
                TIO.putStrLn $ "[stop=" <> Text.pack (show $ amStopReason final) <> "]"
                loop

  loop

-- ─── Utilities ─────────────────────────────────────────────────────────────

sysPrompt :: CliOpts -> Maybe Text
sysPrompt opts = if null (cliSystem opts) then Nothing else Just (Text.pack $ fromMaybe "" (cliSystem opts))

nowMs :: IO Int64
nowMs = round . (* 1000) <$> getPOSIXTime
