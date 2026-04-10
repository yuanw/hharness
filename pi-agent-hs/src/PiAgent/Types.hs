-- | Core data types for pi-agent-hs.
--
-- This module is the Haskell equivalent of the TypeScript @types.ts@.
-- All types are pure (no IO), making them easy to test and serialise.
module PiAgent.Types
  ( -- * Enumerations
    ThinkingLevel (..)
  , ToolExecutionMode (..)
  , StopReason (..)
    -- * Content blocks
  , TextContent (..)
  , ImageContent (..)
  , ContentBlock (..)
  , mkTextBlock
    -- * Messages
  , ToolCall (..)
  , AssistantBlock (..)
  , Message (..)
  , AgentMessage
  , messageRole
    -- * Partial / in-progress streaming message
  , PartialAssistantMessage (..)
  , emptyPartial
  , partialToFinal
    -- * LLM streaming events
  , AssistantMessageEvent (..)
  , eventPartial
    -- * Model and LLM context
  , Model (..)
  , LLMContext (..)
  , LLMTool (..)
  , StreamOptions (..)
  , defaultStreamOptions
    -- * Tool results and tool definition
  , AgentToolResult (..)
  , ToolUpdateCallback
  , AgentTool (..)
    -- * Hook types
  , BeforeToolCallContext (..)
  , BeforeToolCallResult (..)
  , AfterToolCallContext (..)
  , AfterToolCallResult (..)
    -- * Agent context and config
  , AgentContext (..)
  , AgentLoopConfig (..)
    -- * Agent events
  , AgentEvent (..)
  , AgentEventSink
  ) where

import Data.Aeson (Value)
import Data.Int (Int64)
import Data.Set (Set)
import Data.Text (Text)
import GHC.Generics (Generic)

-- ─── Enumerations ──────────────────────────────────────────────────────────

data ThinkingLevel
  = ThinkingOff
  | ThinkingMinimal
  | ThinkingLow
  | ThinkingMedium
  | ThinkingHigh
  | ThinkingXHigh
  deriving (Show, Eq, Ord, Enum, Bounded, Generic)

-- | How tool calls from one assistant turn are executed.
data ToolExecutionMode
  = Sequential  -- ^ One at a time; each finishes before the next starts.
  | Parallel    -- ^ Preflighted sequentially, then all run concurrently.
  deriving (Show, Eq, Ord, Generic)

data StopReason
  = StopEndTurn    -- ^ Model finished naturally.
  | StopToolUse    -- ^ Model is requesting tool calls.
  | StopMaxTokens  -- ^ Context / token limit reached.
  | StopError      -- ^ Provider error.
  | StopAborted    -- ^ Cancelled by the caller.
  deriving (Show, Eq, Ord, Generic)

-- ─── Content ───────────────────────────────────────────────────────────────

newtype TextContent = TextContent { tcText :: Text }
  deriving (Show, Eq, Generic)

data ImageContent = ImageContent
  { icUrl       :: Text
  , icMediaType :: Text
  } deriving (Show, Eq, Generic)

data ContentBlock
  = BlockText  TextContent
  | BlockImage ImageContent
  deriving (Show, Eq, Generic)

mkTextBlock :: Text -> ContentBlock
mkTextBlock = BlockText . TextContent

-- ─── Messages ──────────────────────────────────────────────────────────────

-- | A tool-call block extracted from an AssistantMessage.
-- Corresponds to @AgentToolCall@ in the TypeScript source.
data ToolCall = ToolCall
  { tcId        :: Text
  , tcName      :: Text
  , tcArguments :: Value
  } deriving (Show, Eq, Generic)

-- | A single content item within an AssistantMessage.
data AssistantBlock
  = ABText     Text
  | ABThinking Text
  | ABToolCall ToolCall
  deriving (Show, Eq, Generic)

-- | The three message roles that can appear in a conversation.
data Message
  = UserMessage
    { umContent   :: [ContentBlock]
    , umTimestamp :: Int64
    }
  | AssistantMessage
    { amBlocks     :: [AssistantBlock]
    , amStopReason :: StopReason
    , amErrorMsg   :: Maybe Text
    , amTimestamp  :: Int64
    }
  | ToolResultMessage
    { trmToolCallId :: Text
    , trmToolName   :: Text
    , trmContent    :: [ContentBlock]
    , trmDetails    :: Value
    , trmIsError    :: Bool
    , trmTimestamp  :: Int64
    }
  deriving (Show, Eq, Generic)

-- | @AgentMessage@ is currently a synonym for 'Message'.
-- Applications that need custom message types can introduce a newtype wrapper
-- and supply their own @convertToLlm@ implementation.
type AgentMessage = Message

messageRole :: Message -> Text
messageRole UserMessage{}       = "user"
messageRole AssistantMessage{}  = "assistant"
messageRole ToolResultMessage{} = "toolResult"

-- ─── Partial / in-progress streaming message ──────────────────────────────

-- | Accumulates content while an LLM response is streaming.
-- Becomes a final 'Message' once the stream ends.
data PartialAssistantMessage = PartialAssistantMessage
  { pamBlocks     :: [AssistantBlock]
  , pamStopReason :: StopReason
  , pamErrorMsg   :: Maybe Text
  , pamTimestamp  :: Int64
  } deriving (Show, Eq, Generic)

emptyPartial :: Int64 -> PartialAssistantMessage
emptyPartial ts = PartialAssistantMessage
  { pamBlocks     = []
  , pamStopReason = StopEndTurn
  , pamErrorMsg   = Nothing
  , pamTimestamp  = ts
  }

partialToFinal :: PartialAssistantMessage -> Message
partialToFinal p = AssistantMessage
  { amBlocks     = pamBlocks p
  , amStopReason = pamStopReason p
  , amErrorMsg   = pamErrorMsg p
  , amTimestamp  = pamTimestamp p
  }

-- ─── LLM streaming events ─────────────────────────────────────────────────

-- | Events emitted by the LLM stream.  Each carries the current partial message.
-- Mirrors @AssistantMessageEvent@ from @\@mariozechner\/pi-ai@.
data AssistantMessageEvent
  = EvStart         PartialAssistantMessage
  | EvTextStart     PartialAssistantMessage
  | EvTextDelta     Text PartialAssistantMessage
  | EvTextEnd       PartialAssistantMessage
  | EvThinkingStart PartialAssistantMessage
  | EvThinkingDelta Text PartialAssistantMessage
  | EvThinkingEnd   PartialAssistantMessage
  | EvToolCallStart PartialAssistantMessage
  | EvToolCallDelta PartialAssistantMessage
  | EvToolCallEnd   PartialAssistantMessage
  | EvDone          PartialAssistantMessage
  | EvError         PartialAssistantMessage (Maybe Text)
  deriving (Show, Generic)

-- | Extract the partial message carried by any streaming event.
eventPartial :: AssistantMessageEvent -> PartialAssistantMessage
eventPartial = \case
  EvStart           p   -> p
  EvTextStart       p   -> p
  EvTextDelta     _ p   -> p
  EvTextEnd         p   -> p
  EvThinkingStart   p   -> p
  EvThinkingDelta _ p   -> p
  EvThinkingEnd     p   -> p
  EvToolCallStart   p   -> p
  EvToolCallDelta   p   -> p
  EvToolCallEnd     p   -> p
  EvDone            p   -> p
  EvError           p _ -> p

-- ─── Model and LLM context ─────────────────────────────────────────────────

data Model = Model
  { modelId       :: Text
  , modelProvider :: Text
  , modelContext  :: Int  -- ^ Context window in tokens.
  } deriving (Show, Eq, Generic)

-- | An LLM-facing tool descriptor (schema only, no execution logic).
data LLMTool = LLMTool
  { ltName        :: Text
  , ltDescription :: Text
  , ltSchema      :: Value  -- ^ JSON Schema object.
  } deriving (Show, Eq, Generic)

-- | The context object sent to the LLM on each turn.
data LLMContext = LLMContext
  { lcSystemPrompt :: Text
  , lcMessages     :: [Message]
  , lcTools        :: Maybe [LLMTool]
  } deriving (Show, Generic)

data StreamOptions = StreamOptions
  { soApiKey      :: Maybe Text
  , soTemperature :: Maybe Double
  , soMaxTokens   :: Maybe Int
  , soThinking    :: ThinkingLevel
  } deriving (Show, Generic)

defaultStreamOptions :: StreamOptions
defaultStreamOptions = StreamOptions
  { soApiKey      = Nothing
  , soTemperature = Nothing
  , soMaxTokens   = Nothing
  , soThinking    = ThinkingOff
  }

-- ─── Tools ─────────────────────────────────────────────────────────────────

-- | Result produced by tool execution.
-- @details@ carries arbitrary structured data for logs / UI rendering.
data AgentToolResult details = AgentToolResult
  { toolResContent :: [ContentBlock]
  , toolResDetails :: details
  } deriving (Show, Eq, Generic)

-- | Callback for streaming partial results from a long-running tool.
type ToolUpdateCallback details = AgentToolResult details -> IO ()

-- | An agent tool with type-erased parameter and detail types.
--
-- The agent runtime uses @Value@ everywhere; construct with 'mkAgentTool'
-- to get type-checked argument parsing at the boundary.
data AgentTool = AgentTool
  { atName        :: Text
  , atLabel       :: Text       -- ^ Human-readable name for UI display.
  , atDescription :: Text
  , atSchema      :: Value      -- ^ JSON Schema for parameter documentation.
    -- | Optional shim applied to raw arguments before validation.
    --   Use this for backwards-compatibility argument transforms.
  , atPrepareArgs  :: Maybe (Value -> IO Value)
    -- | Parse and validate raw arguments.  @Left@ carries the error message.
  , atValidateArgs :: Value -> Either Text Value
    -- | Execute the tool.  Must throw on failure (not encode errors in content).
  , atExecute     :: Text                          -- ^ toolCallId
                  -> Value                          -- ^ validated args
                  -> Maybe (IO Bool)               -- ^ cancellation check
                  -> Maybe (ToolUpdateCallback Value)
                  -> IO (AgentToolResult Value)
  }

instance Show AgentTool where
  show t = "AgentTool { atName = " <> show (atName t) <> " }"

-- ─── Hooks ─────────────────────────────────────────────────────────────────

-- | Context passed to the @beforeToolCall@ hook.
data BeforeToolCallContext = BeforeToolCallContext
  { btcAssistantMsg :: Message
  , btcToolCall     :: ToolCall
  , btcArgs         :: Value
  , btcAgentCtx     :: AgentContext
  }

-- | Result from @beforeToolCall@.
-- @BlockCall@ prevents execution; its @Maybe Text@ is the reason shown in the error result.
data BeforeToolCallResult
  = AllowCall
  | BlockCall (Maybe Text)
  deriving (Show, Eq, Generic)

-- | Context passed to the @afterToolCall@ hook.
data AfterToolCallContext = AfterToolCallContext
  { atcAssistantMsg :: Message
  , atcToolCall     :: ToolCall
  , atcArgs         :: Value
  , atcResult       :: AgentToolResult Value
  , atcIsError      :: Bool
  , atcAgentCtx     :: AgentContext
  }

-- | Field-by-field overrides from @afterToolCall@.
-- Omitted fields keep their original values; no deep merge.
data AfterToolCallResult = AfterToolCallResult
  { overContent :: Maybe [ContentBlock]
  , overDetails :: Maybe Value
  , overIsError :: Maybe Bool
  } deriving (Show, Generic)

-- ─── Agent context ─────────────────────────────────────────────────────────

-- | Snapshot passed into the low-level agent loop.
-- The loop mutates its own copy; the caller's original is not changed.
data AgentContext = AgentContext
  { acSystemPrompt :: Text
  , acMessages     :: [AgentMessage]
  , acTools        :: [AgentTool]
  }

instance Show AgentContext where
  show ac =
    "AgentContext { systemPrompt = " <> show (acSystemPrompt ac)
    <> ", messages = " <> show (length (acMessages ac))
    <> ", tools = " <> show (length (acTools ac)) <> " }"

-- ─── Configuration ─────────────────────────────────────────────────────────

-- | All configuration required to run the agent loop.
data AgentLoopConfig = AgentLoopConfig
  { -- | LLM model used for every turn.
    alcModel               :: Model
    -- | Default streaming options; API key may be overridden by 'alcGetApiKey'.
  , alcStreamOptions       :: StreamOptions
    -- | Convert agent messages to LLM-compatible messages before each call.
    --   Filter out UI-only messages here.  Must not throw.
  , alcConvertToLlm        :: [AgentMessage] -> IO [Message]
    -- | Optional pre-LLM transform (context pruning, external injection, …).
    --   Must not throw.
  , alcTransformContext    :: Maybe ([AgentMessage] -> IO [AgentMessage])
    -- | Resolve an API key dynamically (e.g. for short-lived OAuth tokens).
  , alcGetApiKey           :: Maybe (Text -> IO (Maybe Text))
    -- | Steering messages injected mid-run, after tool calls finish.
  , alcGetSteeringMessages :: Maybe (IO [AgentMessage])
    -- | Follow-up messages injected when the agent would otherwise stop.
  , alcGetFollowUpMessages :: Maybe (IO [AgentMessage])
    -- | Sequential or parallel tool execution.
  , alcToolExecution       :: ToolExecutionMode
    -- | Hook called before each tool is executed (after arg validation).
  , alcBeforeToolCall      :: Maybe (BeforeToolCallContext -> IO (Maybe BeforeToolCallResult))
    -- | Hook called after each tool finishes, before final events are emitted.
  , alcAfterToolCall       :: Maybe (AfterToolCallContext -> IO (Maybe AfterToolCallResult))
  }

-- ─── Agent events ──────────────────────────────────────────────────────────

-- | Events emitted during an agent run for UI updates and logging.
data AgentEvent
  = EvAgentStart
  | EvAgentEnd       [AgentMessage]
  | EvTurnStart
  | EvTurnEnd        AgentMessage  [Message]          -- ^ assistant msg, tool results
  | EvMessageStart   AgentMessage
  | EvMessageUpdate  AgentMessage  AssistantMessageEvent
  | EvMessageEnd     AgentMessage
  | EvToolExecStart  Text Text Value                  -- ^ id, name, args
  | EvToolExecUpdate Text Text Value Value            -- ^ id, name, args, partial result
  | EvToolExecEnd    Text Text Value Bool             -- ^ id, name, result, isError
  deriving (Show, Generic)

-- | Receives agent events during a run.
type AgentEventSink = AgentEvent -> IO ()
