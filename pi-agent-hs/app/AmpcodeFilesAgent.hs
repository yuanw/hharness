{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE OverloadedStrings     #-}

-- | Minimal terminal agent from
-- <https://ampcode.com/notes/how-to-build-an-agent>: @read_file@, @list_files@,
-- Claude via Mercury\'s <https://github.com/MercuryTechnologies/claude>
-- bindings, and @pi-agent-hs@ for the tool loop.
module Main (main) where

import Control.Monad (forM, void)
import Data.Aeson (FromJSON (..), Value, withObject, (.:), (.=))
import Data.Foldable (traverse_)
import Data.Maybe (fromMaybe)
import Data.List (isPrefixOf)
import Data.Text (Text)
import System.Directory (canonicalizePath, doesDirectoryExist, doesFileExist, getCurrentDirectory, listDirectory)
import System.Environment (getEnv, lookupEnv)
import System.FilePath (addTrailingPathSeparator, isRelative, makeRelative, normalise, splitDirectories, (</>))
import System.IO (hFlush, hIsEOF, stdin, stdout)

import qualified Claude.V1 as V1
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text.Encoding
import qualified Data.Text.IO as Text.IO

import PiAgent

newtype ReadFileArgs = ReadFileArgs Text

instance FromJSON ReadFileArgs where
  parseJSON = withObject "ReadFileArgs" $ \o ->
    ReadFileArgs <$> o .: "path"

main :: IO ()
main = do
  key <- Text.pack <$> getEnv "ANTHROPIC_KEY"
  baseUrl <- Text.pack . fromMaybe "https://api.anthropic.com" <$> lookupEnv "ANTHROPIC_BASE_URL"
  root <- getCurrentDirectory >>= canonicalizePath
  env <- V1.getClientEnv baseUrl
  let methods = V1.makeMethods env key (Just "2023-06-01")
      streamFn = claudeStreamFn methods
      model =
        Model
          { modelId = defaultClaudeModelId
          , modelProvider = "anthropic"
          , modelContext = 200000
          }
      tools = [readFileTool root, listFilesTool root]
      opts =
        (defaultAgentOptions model streamFn)
          { aoSystemPrompt =
              "You are a helpful assistant. You may use read_file and list_files to inspect the project. "
                <> "Paths are relative to the working directory (root: "
                <> Text.pack root
                <> ")."
          , aoTools = tools
          , aoStreamOptions =
              defaultStreamOptions
                { soMaxTokens = Just 4096
                }
          }
  agent <- newAgent opts
  void $ subscribe agent printEvent
  Text.IO.putStrLn "Chat with Claude (end stdin with Ctrl-d to quit)."
  loop agent
  where
    loop agent = do
      eof <- hIsEOF stdin
      if eof
        then Text.IO.putStrLn "Goodbye."
        else do
          Text.IO.putStr "You: "
          hFlush stdout
          line <- Text.IO.getLine
          promptText agent line
          waitForIdle agent
          loop agent

printEvent :: AgentEvent -> IO ()
printEvent = \case
  EvToolExecStart _ name args ->
    Text.IO.putStrLn $
      "tool: " <> name <> " " <> Text.Encoding.decodeUtf8 (LBS.toStrict (Aeson.encode args))
  EvToolExecEnd _ name _details isErr ->
    Text.IO.putStrLn $
      if isErr then "tool failed: " <> name else "tool done: " <> name
  EvMessageEnd AssistantMessage{amBlocks = bs} -> do
    Text.IO.putStr "Claude: "
    traverse_ printAssistantBlock bs
    Text.IO.putStrLn ""
  EvTurnEnd{} -> pure ()
  EvAgentEnd{} -> pure ()
  _ -> pure ()

printAssistantBlock :: AssistantBlock -> IO ()
printAssistantBlock = \case
  ABText t -> Text.IO.putStr t >> hFlush stdout
  ABThinking t -> Text.IO.putStr ("[thinking] " <> t) >> hFlush stdout
  ABToolCall tc ->
    Text.IO.putStrLn $
      "tool call: " <> tcName tc <> " " <> Text.Encoding.decodeUtf8 (LBS.toStrict (Aeson.encode (tcArguments tc)))

readFileTool :: FilePath -> AgentTool
readFileTool root =
  AgentTool
    { atName = "read_file"
    , atLabel = "read_file"
    , atDescription = "Read a UTF-8 text file relative to the working directory."
    , atSchema = readFileSchema
    , atPrepareArgs = Nothing
    , atValidateArgs = \v ->
        case Aeson.fromJSON v of
          Aeson.Error e -> Left (Text.pack e)
          Aeson.Success (_ :: ReadFileArgs) -> Right v
    , atExecute = \_callId args _cancel _cb -> do
        case Aeson.fromJSON args of
          Aeson.Error e ->
            pure $ mkToolErr (Text.pack e)
          Aeson.Success (ReadFileArgs p) -> do
            let rel = Text.unpack p
            if not (isRelative rel) || ".." `elem` splitDirectories (normalise rel)
              then pure $ mkToolErr "path must be relative and must not contain .."
              else do
                r <- canonicalizePath root
                candidate <- canonicalizePath (normalise (r </> rel))
                let rp = addTrailingPathSeparator r
                if not (rp `isPrefixOf` candidate || candidate == r)
                  then pure $ mkToolErr "path escapes working directory"
                  else do
                    ok <- doesFileExist candidate
                    if not ok
                      then pure $ mkToolErr "file not found"
                      else do
                        txt <- Text.IO.readFile candidate
                        pure
                          AgentToolResult
                            { toolResContent = [mkTextBlock txt]
                            , toolResDetails = Aeson.toJSON ()
                            }
    }
  where
    readFileSchema =
      Aeson.object
        [ "type" .= ("object" :: Text)
        , "properties"
            .= Aeson.object
              [ "path"
                  .= Aeson.object
                    [ "type" .= ("string" :: Text)
                    , "description" .= ("File path relative to cwd" :: Text)
                    ]
              ]
        , "required" .= (["path"] :: [Text])
        ]

mkToolErr :: Text -> AgentToolResult Value
mkToolErr msg =
  AgentToolResult
    { toolResContent = [mkTextBlock msg]
    , toolResDetails = Aeson.toJSON ()
    }

listFilesTool :: FilePath -> AgentTool
listFilesTool root =
  AgentTool
    { atName = "list_files"
    , atLabel = "list_files"
    , atDescription = "List files and directories under the working directory (recursive)."
    , atSchema =
        Aeson.object
          [ "type" .= ("object" :: Text)
          , "properties" .= Aeson.object []
          , "required" .= ([] :: [Text])
          ]
    , atPrepareArgs = Nothing
    , atValidateArgs = \v -> Right v
    , atExecute = \_callId _args _cancel _cb -> do
        paths <- listFilesRel root root
        let txt = Text.intercalate "\n" (map Text.pack paths)
        pure
          AgentToolResult
            { toolResContent = [mkTextBlock txt]
            , toolResDetails = Aeson.toJSON paths
            }
    }

listFilesRel :: FilePath -> FilePath -> IO [FilePath]
listFilesRel root dir = do
  r <- canonicalizePath root
  entries <- listDirectory dir
  fmap concat $ forM entries $ \name -> do
    let full = dir </> name
    f <- canonicalizePath full
    let rel = makeRelative r f
    isDir <- doesDirectoryExist full
    if isDir
      then do
        sub <- listFilesRel root full
        pure ((rel ++ "/") : sub)
      else pure [rel]
