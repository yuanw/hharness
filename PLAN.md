# Plan: Re-implementing pi-mono in Haskell

> Based on a thorough study of the TypeScript source at
> https://github.com/badlogic/pi-mono (ignoring pi-mom, pi-web-ui, pi-pods)
> and the existing Haskell seed at pi-agent-hs.

---

## 1. Architecture Overview

The TypeScript monorepo has four relevant packages:

| TS Package | Purpose | Haskell Target |
|---|---|---|
| `@mariozechner/pi-ai` | Unified multi-provider LLM streaming API (OpenAI, Anthropic, Google, etc.) | `pi-ai` |
| `@mariozechner/pi-agent-core` | Stateful agent loop with tool calling, hooks, steering/follow-up queues | `pi-agent-core` (existing `pi-agent-hs`, renamed & expanded) |
| `@mariozechner/pi-tui` | Terminal UI library with differential rendering, overlays, components | `pi-tui` |
| `@mariozechner/pi-coding-agent` | Interactive coding agent CLI, extensions, sessions, tools | `pi-coding-agent` |

The Haskell project will mirror this as a cabal/stack multi-package repo:

```
pi-mono-hs/
  cabal.project
  pi-ai/          -- LLM provider library
  pi-agent-core/  -- Agent loop & stateful Agent (evolved from current pi-agent-hs)
  pi-tui/          -- Terminal UI library
  pi-coding-agent/ -- Coding agent CLI + extension system
  pi-coding-agent-extensions/  -- Built-in extension examples
```

---

## 2. Package: `pi-ai` — Multi-Provider LLM API

### 2.1 Core Types (`PiAi.Types`)

Mirror the TypeScript `packages/ai/src/types.ts`:

```haskell
data ThinkingLevel = ThinkingOff | ThinkingMinimal | ThinkingLow | ThinkingMedium | ThinkingHigh | ThinkingXHigh
  deriving (Show, Eq, Ord, Enum, Bounded, Generic)

data StopReason = StopEndTurn | StopToolUse | StopMaxTokens | StopError | StopAborted
  deriving (Show, Eq, Ord, Generic)

-- Content blocks
data TextContent = TextContent { tcText :: Text, tcTextSignature :: Maybe Text }
  deriving (Show, Eq, Generic)
data ThinkingContent = ThinkingContent { tcThinking :: Text, tcThinkingSignature :: Maybe Text, tcRedacted :: Maybe Bool }
  deriving (Show, Eq, Generic)
data ImageContent = ImageContent { icData :: Text, icMimeType :: Text }
  deriving (Show, Eq, Generic)

data ToolCall = ToolCall { tcId :: Text, tcName :: Text, tcArguments :: Value, tcThoughtSignature :: Maybe Text }
  deriving (Show, Eq, Generic)

data Usage = Usage { uInput, uOutput, uCacheRead, uCacheWrite, uTotalTokens :: Int, uCost :: Cost }
  deriving (Show, Eq, Generic)
data Cost = Cost { cInput, cOutput, cCacheRead, cCacheWrite, cTotal :: Double }
  deriving (Show, Eq, Generic)

-- Messages
data UserMessage = UserMessage { umContent :: [TextContent | ImageContent], umTimestamp :: Int64 }
data AssistantMessage = AssistantMessage
  { amContent :: [TextContent | ThinkingContent | ToolCall]
  , amApi :: Text, amProvider :: Text, amModel :: Text
  , amResponseId :: Maybe Text
  , amUsage :: Usage, amStopReason :: StopReason, amErrorMessage :: Maybe Text
  , amTimestamp :: Int64
  }
data ToolResultMessage = ToolResultMessage
  { trmToolCallId :: Text, trmToolName :: Text
  , trmContent :: [TextContent | ImageContent]
  , trmDetails :: Maybe Value, trmIsError :: Bool, trmTimestamp :: Int64
  }

type Message = UserMessage | AssistantMessage | ToolResultMessage  -- Using ADT

data Tool = Tool { tName :: Text, tDescription :: Text, tParameters :: Value }

data Model = Model
  { mId :: Text, mName :: Text, mApi :: Text, mProvider :: Text
  , mBaseUrl :: Text, mReasoning :: Bool, mInput :: [Text]
  , mCost :: Cost, mContextWindow :: Int, mMaxTokens :: Int
  , mHeaders :: Maybe (Map Text Text), mCompat :: Maybe Value
  }

data Context = Context
  { cSystemPrompt :: Maybe Text
  , cMessages :: [Message]
  , cTools :: Maybe [Tool]
  }
```

### 2.2 Event Stream (`PiAi.Stream`)

The TypeScript `EventStream<Event, Result>` is an async push/pull stream. The existing `PiAgent.Stream` uses `TQueue (Maybe event)` + `TMVar result`, which is a good match. Reuse and generalize:

```haskell
data EventStream event result = EventStream
  { esQueue  :: TQueue (Maybe event)
  , esResult :: TMVar (Either SomeException result)
  }

newEventStream    :: IO (EventStream event result)
pushEvent         :: EventStream event result -> event -> IO ()
endStream         :: EventStream event result -> result -> IO ()
foldStream        :: EventStream event result -> (event -> IO ()) -> IO result
```

### 2.3 Streaming Events (`PiAi.Events`)

```haskell
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
```

### 2.4 API Registry (`PiAi.Registry`)

Mirror the TypeScript `api-registry.ts` pattern — a global `IORef (Map Api ProviderFn)` keyed by API identifier:

```haskell
type StreamFn   = Model -> Context -> StreamOptions -> IO (EventStream AssistantMessageEvent AssistantMessage)
type StreamSimpleFn = Model -> Context -> SimpleStreamOptions -> IO (EventStream AssistantMessageEvent AssistantMessage)

data ApiProvider = ApiProvider
  { apApi          :: Text
  , apStream       :: StreamFn
  , apStreamSimple :: StreamSimpleFn
  }

newtype ApiRegistry = ApiRegistry (IORef (Map Text ApiProvider))

registerApiProvider :: ApiRegistry -> ApiProvider -> IO ()
getApiProvider    :: ApiRegistry -> Text -> IO (Maybe ApiProvider)
unregisterApiProviders :: ApiRegistry -> Text -> IO ()
```

### 2.5 Provider Implementations (`PiAi.Provider.*`)

Each provider is a separate module:

| Module | API |
|---|---|
| `PiAi.Provider.Anthropic` | `anthropic-messages` |
| `PiAi.Provider.OpenAICompletions` | `openai-completions` |
| `PiAi.Provider.OpenAIResponses` | `openai-responses` |
| `PiAi.Provider.Google` | `google-generative-ai` |
| `PiAi.Provider.Bedrock` | `bedrock-converse-stream` |
| `PiAi.Provider.Mistral` | `mistral-conversations` |
| `PiAi.Provider.Faux` | `faux` (testing) |

Each registers itself into the `ApiRegistry` at init time.

**Streaming**: Use `http-conduit` / `aeson` streaming parsing. Each provider emits `AssistantMessageEvent` values into an `EventStream`.

**Authentication**: `PiAi.Auth` module resolves API keys from env vars, credential files, and runtime resolution callbacks.

### 2.6 Model Generation (`PiAi.Models`)

Port `scripts/generate-models.ts` to a Haskell executable that scrapes provider model lists and writes a `models.generated.hs` data file. At runtime, `PiAi.Models.getModels` reads either the embedded data or a `models.json` from disk.

---

## 3. Package: `pi-agent-core` — Agent Loop & Stateful Agent

This package already has a solid seed in `pi-agent-hs`. The plan is to evolve it.

### 3.1 What Exists

- `PiAgent.Types` — Core types (Messages, ToolCall, AgentTool, hooks, events)
- `PiAgent.Stream` — STM-backed EventStream
- `PiAgent.AgentLoop` — Pure agent loop (runAgentLoop, runAgentLoopContinue)
- `PiAgent.Agent` — Stateful Agent wrapper with TVar-based state, subscribers, queues
- `PiAgent.Claude` — Anthropic provider bridge

### 3.2 What Needs Evolving

The existing types are close but simplified. Changes needed to match the full TypeScript API:

#### 3.2.1 AgentTool upgrades

```haskell
data AgentTool details = AgentTool
  { atName           :: Text
  , atLabel          :: Text          -- NEW: human-readable label
  , atDescription    :: Text
  , atSchema         :: Value
  , atPrepareArgs    :: Maybe (Value -> IO Value)
  , atValidateArgs   :: Value -> Either Text Value
  , atExecute        :: Text -> Value -> Maybe (IO Bool) -> Maybe (ToolUpdateCallback details) -> IO (AgentToolResult details)
  }
```

- Add `atLabel` for UI rendering.
- Make `details` a type parameter throughout (already partially done).

#### 3.2.2 Custom Messages / Extension Messages

The TypeScript has `CustomAgentMessages` via declaration merging. In Haskell, use an existential wrapper:

```haskell
data AgentMessage
  = AMUser UserMessage
  | AMAssistant AssistantMessage
  | AMToolResult ToolResultMessage
  | AMCustom CustomMessage
  deriving (Show)

data CustomMessage = forall a. (Typeable a, Show a, FromJSON a, ToJSON a) => CustomMessage
  { cmType    :: Text
  , cmContent :: a
  , cmDisplay :: Maybe Text
  , cmDetails :: Maybe Value
  }
```

#### 3.2.3 ToolExecutionMode

Already exists as `Sequential | Parallel`. Match the TypeScript preflight-then-execute-in-source-order pattern.

#### 3.2.4 Steering and Follow-Up Queues

Already in `PiAgent.Agent`. Add `QueueMode`:

```haskell
data QueueMode = All | OneAtATime
  deriving (Show, Eq)
```

And wire it into `steer` / `followUp` drain semantics.

#### 3.2.5 ConvertToLlm / TransformContext

Already exist. Keep as-is — these are the right abstraction points.

#### 3.2.6 onPayload / onResponse hooks

Add to `AgentLoopConfig`:

```haskell
  , alcOnPayload    :: Maybe (Value -> Model -> IO (Maybe Value))
  , alcOnResponse   :: Maybe (Int -> Map Text Text -> IO ())
```

---

## 4. Package: `pi-tui` — Terminal UI Library

Port `packages/tui/src/*.ts`. This is ~25 files of terminal rendering infrastructure.

### 4.1 Core Abstractions

```haskell
class Component c where
  render    :: c -> Int -> [Text]    -- width -> lines
  handleInput :: c -> Text -> Maybe c  -- optional key handling
  invalidate :: c -> c               -- clear cached state

data TUI = TUI
  { tuiTerminal    :: TerminalHandle
  , tuiWidth       :: IORef Int
  , tuiHeight      :: IORef Int
  , tuiFocused     :: IORef (Maybe Component)
  , tuiInputListeners :: IORef [InputListener]
  , tuiOverlays    :: IORef [Overlay]
  , tuiRunning     :: IORef Bool
  }
```

### 4.2 Key Subsystems

| TS module | Haskell module | Notes |
|---|---|---|
| `terminal.ts` | `PiTui.Terminal` | Raw terminal I/O via `haskeline` or `vty` |
| `tui.ts` | `PiTui.TUI` | Main loop, diff rendering |
| `keys.ts` | `PiTui.Keys` | Kitty keyboard protocol |
| `keybindings.ts` | `PiTui.Keybindings` | Configurable keybinding maps |
| `fuzzy.ts` | `PiTui.Fuzzy` | Fuzzy matching |
| `autocomplete.ts` | `PiTui.Autocomplete` | Tab completion |
| `components/*.ts` | `PiTui.Component.*` | Box, Editor, Input, Markdown, SelectList, etc. |

### 4.3 Implementation Strategy

Use **`vty`** as the underlying terminal library — it handles resize signals, alternate screen buffer, and mouse/keyboard events. Build the differential renderer on top of `vty` output.

Alternative: use `brick` for the widget set and build custom rendering on top. However, `brick`'s rendering model is immediate-mode, which doesn't match the differential approach in pi-tui. Pure `vty` gives more control.

---

## 5. Package: `pi-coding-agent` — Coding Agent CLI & Extension System

This is the largest package. It ties everything together.

### 5.1 Core Architecture

```
pi-coding-agent/
  src/
    PiCoding/
      Agent/
        Types.hs          -- Extension system types
        Session.hs        -- Session persistence (tree-structured)
        SessionManager.hs -- Session CRUD + branching
        AgentSession.hs   -- Orchestrates Agent + extensions + tools
        Extensions/
          Types.hs         -- ExtensionEvent, ExtensionContext, etc.
          Loader.hs        -- Dynamic loading of extension modules
          Runner.hs         -- Event dispatch to extensions
          EventBus.hs       -- Inter-extension pub/sub
        Tools/
          Bash.hs
          Read.hs
          Edit.hs
          Write.hs
          Grep.hs
          Find.hs
          Ls.hs
          ToolDef.hs       -- ToolDefinition wrapper
        SystemPrompt.hs
        Compaction.hs
        Skills.hs
        SlashCommands.hs
        Config.hs
        ModelRegistry.hs
        ModelResolver.hs
        SettingsManager.hs
        AuthStorage.hs
```

### 5.2 Extension System — Design

The TypeScript extension system is the most architecturally significant piece. It uses:
1. **Dynamic module loading** via `jiti` (TypeScript/JS runtime loading)
2. **Factory function pattern**: each extension exports a default function `(pi: ExtensionAPI) => void`
3. **Registration APIs**: `pi.on()`, `pi.registerTool()`, `pi.registerCommand()`, `pi.registerShortcut()`, etc.
4. **Event-driven lifecycle**: events are dispatched sequentially through all registered handlers
5. **Shared runtime state**: flag values, provider registrations, tool definitions

In Haskell, we can't load arbitrary Haskell modules at runtime. Instead:

#### 5.2.1 Extension Interface (Type-Safe Plugins)

```haskell
-- | An extension is a record of optional handlers and registrations.
-- Extensions are compiled and linked at build time, or loaded via
-- the Lua/Dynload backend (see 5.2.3).
data Extension = Extension
  { extPath           :: FilePath
  , extHandlers       :: Map Text [ExtensionHandler]
  , extTools          :: Map Text RegisteredTool
  , extCommands       :: Map Text RegisteredCommand
  , extFlags          :: Map Text ExtensionFlag
  , extShortcuts      :: Map KeyId ExtensionShortcut
  , extMessageRenderers :: Map Text MessageRenderer
  }

type ExtensionHandler = ExtensionEvent -> ExtensionContext -> IO (Maybe ExtensionEventResult)
```

#### 5.2.2 Extension API (Registration DSL)

```haskell
-- | The API surface exposed to extensions. Built monadically for ergonomics.
newtype ExtensionM a = ExtensionM (State -> IO (a, State))

-- | The DSL that extensions use to register themselves.
class ExtensionFactory e where
  setup :: ExtensionAPI -> IO e

data ExtensionAPI = ExtensionAPI
  { apiOn                 :: forall r. Text -> ExtensionHandler r -> IO ()
  , apiRegisterTool       :: ToolDefinition -> IO ()
  , apiRegisterCommand    :: Text -> CommandOptions -> IO ()
  , apiRegisterShortcut   :: KeyId -> ShortcutOptions -> IO ()
  , apiRegisterFlag       :: Text -> FlagOptions -> IO ()
  , apiRegisterProvider   :: Text -> ProviderConfig -> IO ()
  , apiUnregisterProvider :: Text -> IO ()
  , apiSendMessage        :: CustomMessagePayload -> Maybe SendOptions -> IO ()
  , apiSendUserMessage    :: TextOrContent -> Maybe SendOptions -> IO ()
  , apiEvents             :: EventBus
  -- ... all the fields from the TS ExtensionAPI
  }
```

#### 5.2.3 Dynamic Loading Strategies

Since Haskell doesn't have JS-style `require()`, we offer three approaches:

**Strategy A: Compiled-in Extensions (Primary)**

Extensions are Haskell modules compiled into the binary. The `pi-coding-agent` package lists extension modules explicitly:

```haskell
-- In pi-coding-agent, extensions are registered at startup
loadExtensions :: [ExtensionFactory] -> [FilePath] -> IO LoadExtensionsResult
loadExtensions builtIns paths = do
  -- builtIns are Haskell modules compiled into the binary
  -- paths point to .hs or .lua files that get loaded dynamically
  ...
```

A user's `.pi/config.hs` or project's `.pi/extensions/` directory can specify extension modules:

```haskell
-- ~/.pi/extensions/my-extension.hs
module MyExtension where
import PiCoding.Agent.Extensions.Types

setup :: ExtensionFactory
setup api = do
  apiOn api "tool_call" $ \evt ctx -> ...
  apiRegisterTool api myTool
```

These are compiled at `pi init` time or via GHC's `ghc -dynamic-too` + `GHCi` runtime compilation.

**Strategy B: Lua Extensions (Secondary, for non-Haskell users)**

Implement a Lua sandboxed runtime using `hs-lua`:

```haskell
import Script.Lua

data LuaExtension = LuaExtension
  { luaState :: LuaState
  , luaPath  :: FilePath
  }

loadLuaExtension :: FilePath -> ExtensionAPI -> IO Extension
loadLuaExtension path api = runLua $ do
  -- Expose pi.* API to Lua
  registerHaskellFunction "pi_on" (onHandler api)
  registerHaskellFunction "pi_register_tool" (registerToolHandler api)
  ...
  -- Load and execute the extension file
  dofile path
```

Lua extensions look like:

```lua
-- .pi/extensions/hello.lua
pi.on("tool_call", function(event, ctx)
  if event.toolName == "bash" then
    print("Bash command: " .. event.input.command)
  end
end)

pi.registerTool({
  name = "hello",
  label = "Hello",
  description = "A simple greeting tool",
  parameters = { type = "object", properties = { name = { type = "string" } }, required = {"name"} },
  execute = function(callId, params, signal, onUpdate, ctx)
    return {
      content = { { type = "text", text = "Hello, " .. params.name .. "!" } },
      details = { greeted = params.name }
    }
  end
})
```

**Strategy C: Shared Library Extensions (Advanced)**

Use `System.Dynamic` / `HSffi` for compiled shared objects. Extensions compile to `.so`/`.dylib` and are `dlopen`-ed:

```haskell
loadSharedExtension :: FilePath -> ExtensionAPI -> IO Extension
loadSharedExtension path api = do
  dlfcn <- dlopen path [RTLD_NOW]
  factorySym <- dlsym dlfcn "extensionFactory"
  let factory = castPtr factorySym :: FunPtr (ExtensionAPI -> IO Extension)
  factory api
```

This is the most performant but requires that extension authors use the same GHC version.

#### 5.2.4 Extension Events

Direct port of the TypeScript event taxonomy:

```haskell
data ExtensionEvent
  = EvtResourcesDiscover ResourcesDiscoverEvent
  | EvtSessionStart SessionStartEvent
  | EvtSessionBeforeSwitch SessionBeforeSwitchEvent
  | EvtSessionBeforeFork SessionBeforeForkEvent
  | EvtSessionBeforeCompact SessionBeforeCompactEvent
  | EvtSessionCompact SessionCompactEvent
  | EvtSessionShutdown SessionShutdownEvent
  | EvtSessionBeforeTree SessionBeforeTreeEvent
  | EvtSessionTree SessionTreeEvent
  | EvtContext ContextEvent
  | EvtBeforeProviderRequest BeforeProviderRequestEvent
  | EvtAfterProviderResponse AfterProviderResponseEvent
  | EvtBeforeAgentStart BeforeAgentStartEvent
  | EvtAgentStart AgentStartEvent
  | EvtAgentEnd AgentEndEvent
  | EvtTurnStart TurnStartEvent
  | EvtTurnEnd TurnEndEvent
  | EvtMessageStart MessageStartEvent
  | EvtMessageUpdate MessageUpdateEvent
  | EvtMessageEnd MessageEndEvent
  | EvtToolExecutionStart ToolExecutionStartEvent
  | EvtToolExecutionUpdate ToolExecutionUpdateEvent
  | EvtToolExecutionEnd ToolExecutionEndEvent
  | EvtModelSelect ModelSelectEvent
  | EvtToolCall ToolCallEvent
  | EvtToolResult ToolResultEvent
  | EvtUserBash UserBashEvent
  | EvtInput InputEvent
```

#### 5.2.5 Extension Context

```haskell
data ExtensionContext = ExtensionContext
  { ectxUI              :: ExtensionUIContext
  , ectxHasUI            :: Bool
  , ectxCwd              :: FilePath
  , ectxSessionManager   :: ReadonlySessionManager
  , ectxModelRegistry    :: ModelRegistry
  , ectxModel            :: IO (Maybe Model)
  , ectxIsIdle           :: IO Bool
  , ectxSignal            :: IO (Maybe AbortSignal)
  , ectxAbort            :: IO ()
  , ectxShutdown         :: IO ()
  , ectxGetContextUsage  :: IO (Maybe ContextUsage)
  , ectxCompact          :: Maybe CompactOptions -> IO ()
  , ectxGetSystemPrompt  :: IO Text
  }

data ExtensionCommandContext = ExtensionCommandContext
  { ecmdCtx              :: ExtensionContext
  , ecmdWaitForIdle      :: IO ()
  , ecmdNewSession       :: Maybe NewSessionOptions -> IO NewSessionResult
  , ecmdFork             :: Text -> IO ForkResult
  , ecmdNavigateTree     :: Text -> Maybe NavigateOptions -> IO NavigateResult
  , ecmdSwitchSession    :: FilePath -> IO SwitchResult
  , ecmdReload           :: IO ()
  }
```

#### 5.2.6 Extension Runner

Direct port of `runner.ts`:

```haskell
data ExtensionRunner = ExtensionRunner
  { erExtensions      :: [Extension]
  , erRuntime         :: ExtensionRuntime
  , erUIContext       :: IORef ExtensionUIContext
  , erCwd             :: FilePath
  , erSessionManager  :: SessionManager
  , erModelRegistry   :: ModelRegistry
  , erErrorListeners  :: IORef (Set ExtensionErrorListener)
  , erModel           :: IORef (IO (Maybe Model))
  , erIsIdle          :: IORef (IO Bool)
  -- ... all the action refs from the TS runner
  }
```

Key methods:

```haskell
-- | Emit an event to all extensions sequentially
emit :: ExtensionRunner -> ExtensionEvent -> IO (Maybe ExtensionEventResult)

-- | Emit tool_call event (mutable input, blockable)
emitToolCall :: ExtensionRunner -> ToolCallEvent -> IO (Maybe ToolCallEventResult)

-- | Emit tool_result event (mutable result)
emitToolResult :: ExtensionRunner -> ToolResultEvent -> IO (Maybe ToolResultEventResult)

-- | Emit input event (transform chain)
emitInput :: ExtensionRunner -> Text -> Maybe [ImageContent] -> InputSource -> IO InputEventResult

-- | Discover resource paths from extensions
emitResourcesDiscover :: ExtensionRunner -> FilePath -> Text -> IO ResourcesDiscoverResult
```

### 5.3 Built-In Tools

Each tool becomes a Haskell module:

```haskell
-- PiCoding.Agent.Tools.Bash
createBashTool :: Maybe BashOperations -> FilePath -> AgentTool
createBashTool operations root = AgentTool { ... }

-- PiCoding.Agent.Tools.Read
createReadTool :: FilePath -> AgentTool

-- PiCoding.Agent.Tools.Edit
createEditTool :: FilePath -> AgentTool

-- PiCoding.Agent.Tools.Write
createWriteTool :: FilePath -> AgentTool

-- PiCoding.Agent.Tools.Grep
createGrepTool :: FilePath -> AgentTool

-- PiCoding.Agent.Tools.Find
createFindTool :: FilePath -> AgentTool

-- PiCoding.Agent.Tools.Ls
createLsTool :: FilePath -> AgentTool
```

Tool definitions combine a JSON Schema (via `aeson`) with execution logic. The `ToolDefinition` wrapper adds UI rendering metadata and prompt snippets.

### 5.4 Session Management

The TypeScript uses a tree-structured session format stored as JSONL. Port directly:

```haskell
data SessionEntry
  = EntryUserMessage { ... }
  | EntryAssistantMessage { ... }
  | EntryToolResult { ... }
  | EntryThinking { ... }
  | EntryModelChange { ... }
  | EntryCompaction { ... }
  | EntryLabel { ... }
  | EntryCustom { ... }
  deriving (Show, Generic)

data SessionManager = SessionManager
  { smDir        :: FilePath
  , smCurrent    :: IORef Session
  , smSessionId  :: Text
  }
```

Key operations: `buildSessionContext`, `appendEntry`, `compact`, `fork`, `navigateTree`.

### 5.5 Agent Session Runtime

The `AgentSession` type ties together the Agent, SessionManager, Settings, Extensions, and Tools:

```haskell
data AgentSession = AgentSession
  { asAgent         :: Agent
  , asSessionMgr    :: SessionManager
  , asSettings      :: SettingsManager
  , asExtRunner     :: IORef (Maybe ExtensionRunner)
  , asCwd           :: FilePath
  , asModelRegistry :: ModelRegistry
  , asResourceLoader :: ResourceLoader
  }
```

### 5.6 CLI Modes

Three modes like the TS implementation:

1. **Interactive** — Full TUI (uses `pi-tui`)
2. **Print** — Non-interactive, pipe input/output
3. **RPC** — JSON-RPC over stdio (for IDE integration)

```haskell
main :: IO ()
main = do
  args <- parseArgs
  mode <- resolveMode args
  case mode of
    InteractiveMode -> runInteractive args
    PrintMode       -> runPrint args
    RPCMode         -> runRPC args
```

---

## 6. Dependency Map

```
pi-ai
  └── aeson, http-conduit, http-client-tls, bytestring, text,
       containers, stm, async, time, vector, memory, cryptohash

pi-agent-core
  └── pi-ai, aeson, stm, async, containers, text, time

pi-tui
  └── vty, text, containers, stm, unix, bytestring, terminfo-hs

pi-coding-agent
  └── pi-agent-core, pi-ai, pi-tui, aeson, stm, async,
       directory, filepath, process, optparse-applicative,
       hs-lua (for Lua extensions), cryptonite, memory
```

---

## 7. Implementation Order

| Phase | Package | Milestone |
|---|---|---|
| **1** | `pi-ai` | Types, EventStream, Anthropic provider, API registry |
| **2** | `pi-agent-core` | Evolve existing: upgrade AgentTool, add QueueMode, onPayload/onResponse hooks, CustomMessage support |
| **3** | `pi-ai` | OpenAI, Google, Bedrock providers |
| **4** | `pi-tui` | Terminal, TUI main loop, key handling, basic components (Box, Text, Input, SelectList) |
| **5** | `pi-coding-agent` | CLI skeleton, session manager, tools (bash, read, edit, write), system prompt builder |
| **6** | `pi-coding-agent` | Extension system (Types, Runner, Loader for compiled-in extensions) |
| **7** | `pi-coding-agent` | Lua extension backend, config loading, slash commands |
| **8** | `pi-tui` | Advanced components (Markdown, Editor, autocomplete, overlays) |
| **9** | `pi-coding-agent` | Interactive mode (full TUI), compaction, model cycling |
| **10** | `pi-coding-agent` | RPC mode, print mode, authentication flows |

---

## 8. Testing Strategy

- **pi-ai**: Unit tests for each provider's request/response serialization. Integration tests against real APIs (like existing `stream.test.ts`).
- **pi-agent-core**: Property-based tests (QuickCheck) for the agent loop. Unit tests for state transitions.
- **pi-tui**: Terminal output snapshots. Use `vty` test infrastructure.
- **pi-coding-agent**: End-to-end tests with the `faux` provider (the existing pi-ai faux provider pattern). Golden tests for session serialization.

---

## 9. Deleted File

`pi-agent-hs/app/AmpcodeFilesAgent.hs` has been deleted. The `pi-agent-hs.cabal` file has been updated to remove the `executable ampcode-files-agent` stanza. The `app/` directory has been removed.

The library modules (`PiAgent.Types`, `PiAgent.Stream`, `PiAgent.AgentLoop`, `PiAgent.Agent`, `PiAgent.Claude`) remain intact and will serve as the starting point for the `pi-agent-core` package.