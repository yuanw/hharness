{- | Core data types for hharness-ai.

Mirrors the TypeScript @packages/ai/src/types.ts@.
All types are pure (no IO), making them easy to test and serialise.
-}
module HHAi.Types (
  -- * Enumerations
  ThinkingLevel (..),
  StopReason (..),

  -- * Content blocks
  TextContent (..),
  ThinkingContent (..),
  ImageContent (..),
  UserContent (..),
  AssistantContent (..),
  ToolResultContent (..),
  mkTextContent,

  -- * Tool calls
  ToolCall (..),

  -- * Usage / cost
  Cost (..),
  Usage (..),
  defaultUsage,

  -- * Messages
  UserMessage (..),
  AssistantMessage (..),
  ToolResultMessage (..),
  Message (..),
  messageRole,
  messageTimestamp,

  -- * Partial / in-progress streaming message
  PartialAssistantMessage (..),
  emptyPartial,

  -- * LLM streaming events
  AssistantMessageEvent (..),
  eventPartial,
  eventFinal,

  -- * Model and LLM context
  Model (..),
  Tool (..),
  Context (..),
  StreamOptions (..),
  SimpleStreamOptions (..),
  defaultStreamOptions,

  -- * Provider streaming function types
  StreamFn,
  StreamSimpleFn,
) where

import Data.Aeson (Value)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Text (Text)
import GHC.Generics (Generic)

import HHAi.Stream (EventStream)

-- ─── Enumerations ──────────────────────────────────────────────────────────

data ThinkingLevel
  = ThinkingOff
  | ThinkingMinimal
  | ThinkingLow
  | ThinkingMedium
  | ThinkingHigh
  | ThinkingXHigh
  deriving (Show, Eq, Ord, Enum, Bounded, Generic)

data StopReason
  = StopEndTurn
  | StopToolUse
  | StopMaxTokens
  | StopError
  | StopAborted
  deriving (Show, Eq, Ord, Generic)

-- ─── Content ───────────────────────────────────────────────────────────────

data TextContent = TextContent
  { tcText :: Text
  , tcTextSignature :: Maybe Text
  }
  deriving (Show, Eq, Generic)

data ThinkingContent = ThinkingContent
  { tcThinking :: Text
  , tcThinkingSignature :: Maybe Text
  , tcRedacted :: Maybe Bool
  }
  deriving (Show, Eq, Generic)

data ImageContent = ImageContent
  { icData :: Text
  , icMimeType :: Text
  }
  deriving (Show, Eq, Generic)

data UserContent
  = UCText TextContent
  | UCImage ImageContent
  deriving (Show, Eq, Generic)

data AssistantContent
  = ACText TextContent
  | ACThinking ThinkingContent
  | ACToolCall ToolCall
  deriving (Show, Eq, Generic)

data ToolResultContent
  = TRCText TextContent
  | TRCImage ImageContent
  deriving (Show, Eq, Generic)

mkTextContent :: Text -> TextContent
mkTextContent t = TextContent t Nothing

-- ─── Tool calls ────────────────────────────────────────────────────────────

data ToolCall = ToolCall
  { tcId :: Text
  , tcName :: Text
  , tcArguments :: Value
  , tcThoughtSignature :: Maybe Text
  }
  deriving (Show, Eq, Generic)

-- ─── Usage / cost ──────────────────────────────────────────────────────────

data Cost = Cost
  { cInput :: Double
  , cOutput :: Double
  , cCacheRead :: Double
  , cCacheWrite :: Double
  , cTotal :: Double
  }
  deriving (Show, Eq, Generic)

data Usage = Usage
  { uInput :: Int
  , uOutput :: Int
  , uCacheRead :: Int
  , uCacheWrite :: Int
  , uTotalTokens :: Int
  , uCost :: Cost
  }
  deriving (Show, Eq, Generic)

defaultUsage :: Usage
defaultUsage =
  Usage
    { uInput = 0
    , uOutput = 0
    , uCacheRead = 0
    , uCacheWrite = 0
    , uTotalTokens = 0
    , uCost = Cost 0 0 0 0 0
    }

-- ─── Messages ──────────────────────────────────────────────────────────────

data UserMessage = UserMessage
  { umContent :: [UserContent]
  , umTimestamp :: Int64
  }
  deriving (Show, Eq, Generic)

data AssistantMessage = AssistantMessage
  { amContent :: [AssistantContent]
  , amApi :: Text
  , amProvider :: Text
  , amModel :: Text
  , amResponseId :: Maybe Text
  , amUsage :: Usage
  , amStopReason :: StopReason
  , amErrorMessage :: Maybe Text
  , amTimestamp :: Int64
  }
  deriving (Show, Eq, Generic)

data ToolResultMessage = ToolResultMessage
  { trmToolCallId :: Text
  , trmToolName :: Text
  , trmContent :: [ToolResultContent]
  , trmDetails :: Maybe Value
  , trmIsError :: Bool
  , trmTimestamp :: Int64
  }
  deriving (Show, Eq, Generic)

data Message
  = MsgUser UserMessage
  | MsgAssistant AssistantMessage
  | MsgToolResult ToolResultMessage
  deriving (Show, Eq, Generic)

messageRole :: Message -> Text
messageRole (MsgUser _) = "user"
messageRole (MsgAssistant _) = "assistant"
messageRole (MsgToolResult _) = "toolResult"

messageTimestamp :: Message -> Int64
messageTimestamp (MsgUser u) = umTimestamp u
messageTimestamp (MsgAssistant a) = amTimestamp a
messageTimestamp (MsgToolResult t) = trmTimestamp t

-- ─── Partial / in-progress streaming message ─────────────────────────────

data PartialAssistantMessage = PartialAssistantMessage
  { pamContent :: [AssistantContent]
  , pamStopReason :: StopReason
  , pamErrorMessage :: Maybe Text
  , pamTimestamp :: Int64
  }
  deriving (Show, Eq, Generic)

emptyPartial :: Int64 -> PartialAssistantMessage
emptyPartial ts =
  PartialAssistantMessage
    { pamContent = []
    , pamStopReason = StopEndTurn
    , pamErrorMessage = Nothing
    , pamTimestamp = ts
    }

-- ─── LLM streaming events ─────────────────────────────────────────────────

data AssistantMessageEvent
  = EvStart PartialAssistantMessage
  | EvTextStart Int PartialAssistantMessage
  | EvTextDelta Int Text PartialAssistantMessage
  | EvTextEnd Int Text PartialAssistantMessage
  | EvThinkingStart Int PartialAssistantMessage
  | EvThinkingDelta Int Text PartialAssistantMessage
  | EvThinkingEnd Int Text PartialAssistantMessage
  | EvToolCallStart Int PartialAssistantMessage
  | EvToolCallDelta Int Text PartialAssistantMessage
  | EvToolCallEnd Int ToolCall PartialAssistantMessage
  | EvDone StopReason AssistantMessage
  | EvError StopReason Text AssistantMessage
  deriving (Show, Generic)

{- | Extract the partial message carried by a streaming event.
Returns 'Nothing' for terminal events.
-}
eventPartial :: AssistantMessageEvent -> Maybe PartialAssistantMessage
eventPartial = \case
  EvStart p -> Just p
  EvTextStart _ p -> Just p
  EvTextDelta _ _ p -> Just p
  EvTextEnd _ _ p -> Just p
  EvThinkingStart _ p -> Just p
  EvThinkingDelta _ _ p -> Just p
  EvThinkingEnd _ _ p -> Just p
  EvToolCallStart _ p -> Just p
  EvToolCallDelta _ _ p -> Just p
  EvToolCallEnd _ _ p -> Just p
  EvDone _ _ -> Nothing
  EvError _ _ _ -> Nothing

-- | Extract the final message from a terminal event.
eventFinal :: AssistantMessageEvent -> Maybe AssistantMessage
eventFinal = \case
  EvDone _ final -> Just final
  EvError _ _ final -> Just final
  _ -> Nothing

-- ─── Model and LLM context ─────────────────────────────────────────────────

data Model = Model
  { mId :: Text
  , mName :: Text
  , mApi :: Text
  , mProvider :: Text
  , mBaseUrl :: Text
  , mReasoning :: Bool
  , mInput :: [Text]
  , mCost :: Cost
  , mContextWindow :: Int
  , mMaxTokens :: Int
  , mHeaders :: Maybe (Map Text Text)
  , mCompat :: Maybe Value
  }
  deriving (Show, Eq, Generic)

data Tool = Tool
  { tName :: Text
  , tDescription :: Text
  , tParameters :: Value
  }
  deriving (Show, Eq, Generic)

data Context = Context
  { cSystemPrompt :: Maybe Text
  , cMessages :: [Message]
  , cTools :: Maybe [Tool]
  }
  deriving (Show, Generic)

data StreamOptions = StreamOptions
  { soApiKey :: Maybe Text
  , soTemperature :: Maybe Double
  , soMaxTokens :: Maybe Int
  , soThinking :: ThinkingLevel
  }
  deriving (Show, Generic)

data SimpleStreamOptions = SimpleStreamOptions
  { ssoApiKey :: Maybe Text
  , ssoTemperature :: Maybe Double
  , ssoMaxTokens :: Maybe Int
  }
  deriving (Show, Generic)

defaultStreamOptions :: StreamOptions
defaultStreamOptions =
  StreamOptions
    { soApiKey = Nothing
    , soTemperature = Nothing
    , soMaxTokens = Nothing
    , soThinking = ThinkingOff
    }

-- ─── Provider streaming function types ─────────────────────────────────────

type StreamFn =
  Model ->
  Context ->
  StreamOptions ->
  IO (EventStream AssistantMessageEvent AssistantMessage)

type StreamSimpleFn =
  Model ->
  Context ->
  SimpleStreamOptions ->
  IO (EventStream AssistantMessageEvent AssistantMessage)
