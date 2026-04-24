{- | Hard-coded model metadata.

A future generator can scrape provider APIs; for now we embed the two
supported providers in a plain Haskell list.
-}
module HHAi.Models (
  getModels,
  getModelById,
  defaultAnthropicModels,
  defaultOpenAIModels,
) where

import Data.List (find)
import Data.Text (Text)

import HHAi.Types

-- ─── Public API ────────────────────────────────────────────────────────────

-- | All built-in models.
getModels :: IO [Model]
getModels = pure (defaultAnthropicModels <> defaultOpenAIModels)

-- | Lookup a built-in model by its identifier.
getModelById :: Text -> IO (Maybe Model)
getModelById mid = find ((== mid) . mId) <$> getModels

-- ─── Anthropic ─────────────────────────────────────────────────────────────

defaultAnthropicModels :: [Model]
defaultAnthropicModels =
  [ Model
      { mId = "claude-sonnet-4-5-20250929"
      , mName = "Claude Sonnet 4.5"
      , mApi = "anthropic-messages"
      , mProvider = "anthropic"
      , mBaseUrl = "https://api.anthropic.com"
      , mReasoning = True
      , mInput = ["text", "image"]
      , mCost = Cost 3.0 15.0 0.3 3.75 0
      , mContextWindow = 200_000
      , mMaxTokens = 8192
      , mHeaders = Nothing
      , mCompat = Nothing
      }
  , Model
      { mId = "claude-opus-4-5-20250929"
      , mName = "Claude Opus 4.5"
      , mApi = "anthropic-messages"
      , mProvider = "anthropic"
      , mBaseUrl = "https://api.anthropic.com"
      , mReasoning = True
      , mInput = ["text", "image"]
      , mCost = Cost 15.0 75.0 1.5 18.75 0
      , mContextWindow = 200_000
      , mMaxTokens = 8192
      , mHeaders = Nothing
      , mCompat = Nothing
      }
  ]

-- ─── OpenAI ────────────────────────────────────────────────────────────────

defaultOpenAIModels :: [Model]
defaultOpenAIModels =
  [ Model
      { mId = "gpt-4o"
      , mName = "GPT-4o"
      , mApi = "openai-responses"
      , mProvider = "openai"
      , mBaseUrl = "https://api.openai.com"
      , mReasoning = False
      , mInput = ["text", "image"]
      , mCost = Cost 2.5 10.0 1.25 0.0 0
      , mContextWindow = 128_000
      , mMaxTokens = 16384
      , mHeaders = Nothing
      , mCompat = Nothing
      }
  , Model
      { mId = "gpt-4o-mini"
      , mName = "GPT-4o Mini"
      , mApi = "openai-responses"
      , mProvider = "openai"
      , mBaseUrl = "https://api.openai.com"
      , mReasoning = False
      , mInput = ["text", "image"]
      , mCost = Cost 0.15 0.6 0.075 0.0 0
      , mContextWindow = 128_000
      , mMaxTokens = 16384
      , mHeaders = Nothing
      , mCompat = Nothing
      }
  , Model
      { mId = "o3-mini"
      , mName = "o3-mini"
      , mApi = "openai-responses"
      , mProvider = "openai"
      , mBaseUrl = "https://api.openai.com"
      , mReasoning = True
      , mInput = ["text"]
      , mCost = Cost 1.1 4.4 0.55 0.0 0
      , mContextWindow = 200_000
      , mMaxTokens = 100_000
      , mHeaders = Nothing
      , mCompat = Nothing
      }
  ]
