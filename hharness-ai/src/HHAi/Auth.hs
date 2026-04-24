{- | API key resolution.

Tries, in order:
1. Environment variable (e.g. @ANTHROPIC_API_KEY@, @OPENAI_API_KEY@)
2. Credential file (~/.hharness/auth.json) — not yet implemented
3. Runtime resolution callback — not yet implemented
-}
module HHAi.Auth (
  resolveApiKey,
) where

import Data.Text (Text)
import Data.Text qualified as Text
import System.Environment (lookupEnv)

-- | Resolve an API key for the given API identifier.
resolveApiKey :: Text -> IO (Maybe Text)
resolveApiKey api = case api of
  "anthropic-messages" -> env "ANTHROPIC_API_KEY"
  "openai-responses" -> env "OPENAI_API_KEY"
  "openai-completions" -> env "OPENAI_API_KEY"
  "faux" -> pure (Just "faux-key")
  _ -> env (Text.unpack (Text.toUpper api <> "_API_KEY"))
  where
    env :: String -> IO (Maybe Text)
    env var = fmap Text.pack <$> lookupEnv var
