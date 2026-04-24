{- | Global API registry.

Mirrors the TypeScript @api-registry.ts@ pattern: a mutable map keyed by
API identifier (e.g. @"anthropic-messages"@).
Providers register themselves at init time.
-}
module HHAi.Registry (
  ApiProvider (..),
  ApiRegistry,
  newRegistry,
  registerApiProvider,
  getApiProvider,
  unregisterApiProviders,
) where

import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)

import HHAi.Types (StreamFn, StreamSimpleFn)

-- ─── Types ─────────────────────────────────────────────────────────────────

data ApiProvider = ApiProvider
  { apApi :: Text
  , apStream :: StreamFn
  , apStreamSimple :: StreamSimpleFn
  }

newtype ApiRegistry = ApiRegistry (IORef (Map Text ApiProvider))

-- ─── Public API ────────────────────────────────────────────────────────────

-- | Allocate an empty registry.
newRegistry :: IO ApiRegistry
newRegistry = ApiRegistry <$> newIORef Map.empty

-- | Register (or overwrite) a provider under its 'apApi' key.
registerApiProvider :: ApiRegistry -> ApiProvider -> IO ()
registerApiProvider (ApiRegistry ref) provider =
  atomicModifyIORef' ref $ \m -> (Map.insert (apApi provider) provider m, ())

-- | Lookup a provider by API identifier.
getApiProvider :: ApiRegistry -> Text -> IO (Maybe ApiProvider)
getApiProvider (ApiRegistry ref) api =
  Map.lookup api <$> readIORef ref

-- | Remove a provider by API identifier.
unregisterApiProviders :: ApiRegistry -> Text -> IO ()
unregisterApiProviders (ApiRegistry ref) api =
  atomicModifyIORef' ref $ \m -> (Map.delete api m, ())
