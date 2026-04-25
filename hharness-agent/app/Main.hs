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

import Control.Exception (IOException, SomeException, try)
import Control.Monad (forM_, unless, when)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.IORef
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Data.Time.Clock.POSIX (getPOSIXTime)
import Options.Applicative
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Environment (lookupEnv)
import System.FilePath (takeDirectory)
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
  , cliTools :: Bool
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
    <*> switch
      ( long "no-tools"
          <> help "Disable tool calling in interactive mode"
      )

parserInfo :: ParserInfo CliOpts
parserInfo =
  info
    (optsParser <**> helper)
    ( fullDesc
        <> progDesc "Send user messages to an LLM. Use --interactive for multi-turn REPL with file tools."
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

-- ═════════════════════════════════════════════════════════════════════════════
--  Tool definitions
-- ═════════════════════════════════════════════════════════════════════════════

fileTools :: Maybe [Tool]
fileTools =
  Just
    [ Tool
        { tName = "read_file"
        , tDescription = "Read the contents of a file at the given path. Returns the file text content."
        , tParameters =
            object
              [ "type" .= String "object"
              , "properties"
                  .= object
                    [ "path" .= object ["type" .= String "string", "description" .= String "Absolute or relative file path to read"]
                    ]
              , "required" .= [String "path"]
              ]
        }
    , Tool
        { tName = "write_file"
        , tDescription = "Write content to a file at the given path. Creates parent directories if needed."
        , tParameters =
            object
              [ "type" .= String "object"
              , "properties"
                  .= object
                    [ "path" .= object ["type" .= String "string", "description" .= String "Absolute or relative file path to write"]
                    , "content" .= object ["type" .= String "string", "description" .= String "Text content to write"]
                    ]
              , "required" .= [String "path", String "content"]
              ]
        }
    ]

-- | Extract a string field from a JSON object Value.
lookupText :: Text -> Value -> Maybe Text
lookupText key (Object obj) =
  case KM.lookup (Key.fromText key) obj of
    Just (String t) -> Just t
    _ -> Nothing
lookupText _ _ = Nothing

-- | Execute a single tool call and return a ToolResultMessage.
executeToolCall :: ToolCall -> IO ToolResultMessage
executeToolCall tc = do
  ts <- nowMs
  let name = tcName tc
      args = tcArguments tc
      pathM = lookupText "path" args
      contentM = lookupText "content" args
      success txt =
        ToolResultMessage
          { trmToolCallId = tcId tc
          , trmToolName = name
          , trmContent = [TRCText $ TextContent txt Nothing]
          , trmDetails = Nothing
          , trmIsError = False
          , trmTimestamp = ts
          }
      err txt =
        ToolResultMessage
          { trmToolCallId = tcId tc
          , trmToolName = name
          , trmContent = [TRCText $ TextContent txt Nothing]
          , trmDetails = Nothing
          , trmIsError = True
          , trmTimestamp = ts
          }
  case (name, pathM, contentM) of
    ("read_file", Just path, _) -> do
      exists <- doesFileExist (Text.unpack path)
      if not exists
        then pure $ err $ "File not found: " <> path
        else do
          content <- try @SomeException $ TIO.readFile (Text.unpack path)
          case content of
            Left e -> pure $ err $ "Read error: " <> Text.pack (show e)
            Right txt -> pure $ success txt
    ("write_file", Just path, Just content) -> do
      result <- try @SomeException $ do
        createDirectoryIfMissing True (takeDirectory (Text.unpack path))
        TIO.writeFile (Text.unpack path) content
      case result of
        Left e -> pure $ err $ "Write error: " <> Text.pack (show e)
        Right () -> pure $ success $ "Wrote " <> Text.pack (show (Text.length content)) <> " chars to " <> path
    ("write_file", Just _, Nothing) -> pure $ err "Missing 'content' argument"
    _ -> pure $ err $ "Unknown tool or missing arguments: " <> name

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
        , cTools = if cliTools opts then fileTools else Nothing
        }

  let sopts = defaultStreamOptions {soApiKey = Nothing, soMaxTokens = Just 2048}

  when useLog $ putStrLn $ "[logging to " ++ logPath ++ "]"
  TIO.putStrLn "Interactive mode. Type /quit, /exit, or /q to leave."

  -- \| Print events and accumulate text output for one LLM turn.
  let streamHandler ev = case ev of
        EvTextDelta _ txt _ -> TIO.putStr txt
        EvToolCallStart _ _ -> pure ()
        EvToolCallDelta {} -> pure ()
        EvToolCallEnd _ tc _ -> TIO.putStrLn $ "\n[tool: " <> tcName tc <> "]"
        EvDone _ _ -> TIO.putStrLn ""
        EvError _ msg _ -> TIO.putStrLn $ "\n[error: " <> msg <> "]"
        _ -> pure ()

  -- \| Run one turn, handling tool calls in a loop until the model stops.
  let runAgentTurn = do
        ctx <- readIORef ctxRef
        es <- streamFn model ctx sopts
        final <- foldStream es streamHandler
        let finalMsg = MsgAssistant final
        modifyIORef' ctxRef $ \c -> c {cMessages = cMessages c <> [finalMsg]}
        case amStopReason final of
          StopToolUse -> do
            let toolCalls = [tc | ACToolCall tc <- amContent final]
            unless (null toolCalls) $ do
              TIO.putStrLn "[executing tools...]"
              forM_ toolCalls $ \tc -> do
                result <- executeToolCall tc
                TIO.putStrLn $
                  "  ["
                    <> tcName tc
                    <> " "
                    <> tcId tc
                    <> "] "
                    <> if trmIsError result then "ERROR" else "OK"
                modifyIORef' ctxRef $ \c -> c {cMessages = cMessages c <> [MsgToolResult result]}
              runAgentTurn -- stream again with tool results
          _ -> pure ()

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
                runAgentTurn
                TIO.putStrLn "[turn end]"
                loop

  loop

-- ─── Utilities ─────────────────────────────────────────────────────────────

sysPrompt :: CliOpts -> Maybe Text
sysPrompt opts = if null (cliSystem opts) then Nothing else Just (Text.pack $ fromMaybe "" (cliSystem opts))

nowMs :: IO Int64
nowMs = round . (* 1000) <$> getPOSIXTime
