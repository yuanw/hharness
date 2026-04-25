{- | Load model definitions from the user's $HOME/.pi/agent/models.json.

This file is also used by the TypeScript @pi@ tooling.  We read the same
format so that hharness and pi share a single source of truth for local
model definitions (e.g. Ollama endpoints).
-}
module HHAi.Models.Json (
  loadModelsFromFile,
  loadUserModels,
  loadModelById,
) where

import Control.Exception (try)
import Data.Aeson (FromJSON (..), eitherDecode, withObject, (.:))
import Data.ByteString.Lazy qualified as BSL
import Data.List (find)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import System.Directory (getHomeDirectory)
import System.FilePath ((</>))

import HHAi.Models (defaultAnthropicModels, defaultOpenAIModels)
import HHAi.Types (Cost (..), Model (..))

-- ─── Intermediate types for JSON parsing ────────────────────────────────────

newtype ModelsJson = ModelsJson
  { mjProviders :: Map Text ProviderConfig
  }
  deriving (Show)

instance FromJSON ModelsJson where
  parseJSON = withObject "ModelsJson" $ \o -> do
    ps <- o .: "providers"
    pure $ ModelsJson ps

data ProviderConfig = ProviderConfig
  { pcApi :: Text
  , pcApiKey :: Text
  , pcBaseUrl :: Text
  , pcModels :: [ModelStub]
  }
  deriving (Show)

instance FromJSON ProviderConfig where
  parseJSON = withObject "ProviderConfig" $ \o -> do
    pcApi <- o .: "api"
    pcApiKey <- o .: "apiKey"
    pcBaseUrl <- o .: "baseUrl"
    pcModels <- o .: "models"
    pure ProviderConfig {..}

data ModelStub = ModelStub
  { msId :: Text
  , msContextWindow :: Int
  , msInput :: [Text]
  , msReasoning :: Bool
  }
  deriving (Show)

instance FromJSON ModelStub where
  parseJSON = withObject "ModelStub" $ \o -> do
    msId <- o .: "id"
    msContextWindow <- o .: "contextWindow"
    msInput <- o .: "input"
    msReasoning <- o .: "reasoning"
    pure ModelStub {..}

-- ─── Public API ────────────────────────────────────────────────────────────

{- | Read a models.json file and convert to `Model` records.
Returns 'Left' with an error description if the file is missing or malformed.
-}
loadModelsFromFile :: FilePath -> IO (Either Text [Model])
loadModelsFromFile path = do
  result <- try @IOError (BSL.readFile path)
  case result of
    Left _ -> pure $ Left (Text.pack $ "Could not read: " ++ path)
    Right raw -> case eitherDecode @ModelsJson raw of
      Left err -> pure $ Left (Text.pack $ "JSON parse error: " ++ err)
      Right mj -> pure $ Right (Map.foldMapWithKey providerModels (mjProviders mj))

{- | Load from the default location ($HOME/.pi/agent/models.json).
If the file is missing or unreadable, fall back to built-in models.
-}
loadUserModels :: IO [Model]
loadUserModels = do
  home <- getHomeDirectory
  let path = home </> ".pi/agent/models.json"
  er <- loadModelsFromFile path
  case er of
    Left _ -> pure (defaultAnthropicModels ++ defaultOpenAIModels)
    Right ms -> pure (defaultAnthropicModels ++ defaultOpenAIModels ++ ms)

-- | Lookup a model by identifier from all available sources.
loadModelById :: Text -> IO (Maybe Model)
loadModelById mid = find (\m -> mId m == mid) <$> loadUserModels

-- ─── Internal conversions ──────────────────────────────────────────────────

providerModels :: Text -> ProviderConfig -> [Model]
providerModels providerName pc =
  map
    ( \m ->
        Model
          { mId = msId m
          , mName = msId m
          , mApi = pcApi pc
          , mProvider = providerName
          , mBaseUrl = pcBaseUrl pc
          , mReasoning = msReasoning m
          , mInput = msInput m
          , mCost = Cost 0 0 0 0 0
          , mContextWindow = msContextWindow m
          , mMaxTokens = msContextWindow m `div` 2
          , mHeaders = Nothing
          , mCompat = Nothing
          }
    )
    (pcModels pc)
