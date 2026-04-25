# Plan: hharness — Re-implementing pi-mono in Haskell

> Based on a thorough study of the TypeScript source at
> https://github.com/badlogic/pi-mono (ignoring pi-mom, pi-web-ui, pi-pods)
> and the existing Haskell seed (formerly pi-agent-hs, now hharness-agent).

---

## 1. Architecture Overview

The TypeScript monorepo has four relevant packages:

| TS Package | Purpose | Haskell Target |
|---|---|---|
| `@mariozechner/pi-ai` | Unified multi-provider LLM streaming API (OpenAI, Anthropic, Google, etc.) | `hharness-ai` |
| `@mariozechner/pi-agent-core` | Stateful agent loop with tool calling, hooks, steering/follow-up queues | `hharness-agent` |
| `@mariozechner/pi-tui` | Terminal UI library with differential rendering, overlays, components | `hharness-tui` |
| `@mariozechner/pi-coding-agent` | Interactive coding agent CLI, extensions, sessions, tools | `hharness-coding` |

The Haskell project will mirror this as a cabal/stack multi-package repo:

```
hharness/
  cabal.project
  hharness-ai/          -- LLM provider library
  hharness-agent/      -- Agent loop & stateful Agent
  hharness-tui/          -- Terminal UI library
  hharness-coding/ -- Coding agent CLI + extension system
  hharness-coding-extensions/  -- Built-in extension examples
```

---

## 2. Package: `hharness-ai` — Multi-Provider LLM API

### 2.1 Core Types (`HHAi.Types`)

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

### 2.2 Event Stream (`HHAi.Stream`)

The TypeScript `EventStream<Event, Result>` is an async push/pull stream. The existing `HHAgent.Stream` uses `TQueue (Maybe event)` + `TMVar result`, which is a good match. Reuse and generalize:

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

### 2.3 Streaming Events (`HHAi.Events`)

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

### 2.4 API Registry (`HHAi.Registry`)

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

### 2.5 Provider Implementations (`HHAi.Provider.*`)

We initially target two providers — Anthropic and OpenAI — plus a faux provider for testing. The registry pattern makes adding more providers straightforward later.

| Module | API | Notes |
|---|---|---|
| `HHAi.Provider.Anthropic` | `anthropic-messages` | Uses [MercuryTechnologies/claude](https://github.com/MercuryTechnologies/claude) Haskell package. Already implemented in `HHAgent.Claude`; port to `hharness-ai`. |
| `HHAi.Provider.OpenAI` | `openai-responses` + `openai-completions` | Uses [MercuryTechnologies/openai](https://github.com/MercuryTechnologies/openai) Haskell package. Supports completions, responses, and streaming SSE. |
| `HHAi.Provider.Faux` | `faux` | Testing provider that returns canned responses without calling any API. |

Each registers itself into the `ApiRegistry` at init time.

#### Anthropic Provider (`HHAi.Provider.Anthropic`)

The existing `HHAgent.Claude` module already implements `StreamFn` via Mercury's `claude` package. Port this to `hharness-ai` with the following improvements:

- Support streaming (SSE) in addition to the current blocking `createMessage` call
- Map `MessageResponse` content blocks to `AssistantMessageEvent` values
- Handle thinking blocks, tool-use blocks, and redacted-thinking blocks
- Support `claudeStreamFnCompat` for proxies that omit `signature` on thinking blocks
- API key resolution from `ANTHROPIC_API_KEY` env var, `~/.hharness/auth.json`, or runtime callback
- Base URL override from `ANTHROPIC_BASE_URL` env var

#### OpenAI Provider (`HHAi.Provider.OpenAI`)

Uses [MercuryTechnologies/openai](https://github.com/MercuryTechnologies/openai) which provides:

- Types for the OpenAI Chat Completions API (`/v1/chat/completions`)
- Types for the OpenAI Responses API (`/v1/responses`)
- Streaming SSE support
- Tool/function calling

The provider will implement two API identifiers:

1. **`openai-completions`** — Chat Completions API. Maps to the `openai` package's `CreateChatCompletionRequest` / streaming types.
2. **`openai-responses`** — Responses API. Maps to the `openai` package's `CreateResponseRequest` types.

Key responsibilities:

- Convert `Message` to OpenAI message format (`HHAi.Provider.OpenAI.Convert`)
- Handle streaming SSE events, mapping deltas to `AssistantMessageEvent`
- Support `store`, `reasoning_effort`, `developer` role, and other compat options
- API key from `OPENAI_API_KEY` env var or runtime callback
- Base URL override for Azure, OpenRouter, and other OpenAI-compatible providers
- Handle model-specific behavior (GPT-4, o1/o3 reasoning, etc.)

#### Faux Provider (`HHAi.Provider.Faux`)

Port the TypeScript `faux` provider for deterministic testing. Returns canned assistant messages with configurable delays, stop reasons, and tool calls. Essential for unit testing the agent loop without API calls.

**Streaming**: Both Anthropic and OpenAI providers emit `AssistantMessageEvent` values into an `EventStream` via SSE parsing. The `http-conduit` and `aeson` packages handle HTTP and JSON; the `openai` and `claude` packages handle provider-specific response types.

**Authentication**: `HHAi.Auth` module resolves API keys from environment variables, credential files (`~/.hharness/auth.json`), and runtime resolution callbacks.

### 2.6 Model Generation (`HHAi.Models`)

Hard-code model metadata for the two supported providers in a Haskell data file. Initially cover:

- **Anthropic**: `claude-sonnet-4-5-20250514`, `claude-opus-4-5-20250514`, etc.
- **OpenAI**: `gpt-4o`, `gpt-4o-mini`, `o1-pro`, `o3-mini`, etc.

At runtime, `HHAi.Models.getModels` reads either the embedded data or a `models.json` from disk (allowing users to add custom endpoints). A future generator executable can scrape provider APIs, but is not required initially.

---

## 3. Package: `hharness-agent` — Agent Loop & Stateful Agent

This package already has a solid seed in the existing `hharness-agent` codebase. The plan is to evolve it.

### 3.1 What Exists

- `HHAgent.Types` — Core types (Messages, ToolCall, AgentTool, hooks, events)
- `HHAgent.Stream` — STM-backed EventStream
- `HHAgent.AgentLoop` — Pure agent loop (runAgentLoop, runAgentLoopContinue)
- `HHAgent.Agent` — Stateful Agent wrapper with TVar-based state, subscribers, queues
- `HHAgent.Claude` — Anthropic provider bridge

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

Already in `HHAgent.Agent`. Add `QueueMode`:

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

## 4. Package: `hharness-tui` — Terminal UI Library

Port `packages/tui/src/*.ts`. This is ~25 files of terminal rendering infrastructure.

### 4.1 Use `brick` (built on `vty`)

The original TypeScript pi-tui builds its own differential renderer, overlay system, focus management, and component model from scratch on raw terminal I/O. In Haskell, **`brick`** already provides all of this:

- **Differential rendering**: `brick` uses `vty` underneath and handles double-buffering and screen diffs automatically. `brick`'s `render` produces a `Picture` each frame, and `vty` diffs it against the last frame — exactly what the TypeScript pi-tui's `doRender()` does.
- **Component/Widget model**: the TypeScript pi-tui's `Component` interface (`render(width) -> string[]`, `handleInput`) maps directly to `brick`'s `Widget` plus event handling. Every TypeScript pi-tui component (Box, Text, Input, Editor, SelectList, Markdown, etc.) becomes a `brick` `Widget`.
- **Overlay system**: the TypeScript pi-tui's overlay stack with anchoring, positioning, focus management, and z-ordering maps to `brick`'s layered rendering. Overlays that capture focus become modal dialogs; non-capturing overlays become background layers.
- **Key handling**: the TypeScript pi-tui's Kitty keyboard protocol support maps to `vty`'s `Event` type, which already handles Kitty and extended key sequences.
- **Focus management**: the TypeScript pi-tui's `focused` flag and `setFocus()` map to `brick`'s `FocusRing`.
- **Cursor positioning**: the TypeScript pi-tui's `CURSOR_MARKER` maps to `brick`'s `ShowCursor` / `CursorPosition`.
- **Image support**: the TypeScript pi-tui's terminal image protocol support (SIXEL, Kitty, etc.) can be layered on top of `vty`'s raw output, same as pi-tui does.

Using `brick` saves writing ~1500 lines of terminal rendering infrastructure that the original TypeScript pi-tui reimplements.

### 4.2 Core Architecture

```haskell
-- | The main TUI application state
data AppState = AppState
  { appAgent         :: MVar AgentSession
  , appExtensions    :: ExtensionRunner
  , appSessionMgr    :: SessionManager
  , appSettings      :: SettingsManager
  , appTheme         :: Theme
  , appKeybindings   :: KeybindingsConfig
  , appMode          :: AppMode
  , appFocusedWidget :: FocusRing ResourceName
  }

data AppMode
  = ModeChat
  | ModeEditor
  | ModeSelector
  | ModeOverlay OverlayState

data ResourceName
  = EditorInput
  | MessageViewport
  | ToolOutputView
  | StatusBar
  | ModelSelector
  | SessionSelector
  deriving (Show, Eq, Ord)

-- | The brick App definition
app :: App AppState AppEvent ResourceName
app = App
  { appDraw         = drawApp
  , appChooseCursor = showFirstCursor
  , appHandleEvent  = handleAppEvent
  , appStartEvent   = appStart
  , appAttrMap      = attrMapFromTheme
  }
```

### 4.3 Key Subsystems

| TS module | Haskell module | brick equivalent |
|---|---|---|
| `terminal.ts` | Uses `vty` directly through brick | `vty` handles raw terminal, resize, alt screen |
| `tui.ts` | `HHTui.App` | `brick` `App` handles main loop, diff rendering, focus, overlays |
| `keys.ts` | `vty` key event parsing | `vty` already handles Kitty protocol and extended keys |
| `keybindings.ts` | `HHTui.Keybindings` | Configurable keybinding map checked in `handleEvent` |
| `fuzzy.ts` | `HHTui.Fuzzy` | Pure fuzzy matching (used in selectors) |
| `autocomplete.ts` | `HHTui.Autocomplete` | Completion overlay widget |
| `components/*.ts` | `HHTui.Widget.*` | Each becomes a `Widget n` |
| `stdin-buffer.ts` | N/A | `brick` handles input buffering |
| `editor-component.ts` | `HHTui.Widget.Editor` | Extend `Brick.Widgets.Edit.Editor` (multiline) |
| `image.ts` | `HHTui.Image` | SIXEL/Kitty image protocol on top of `vty` raw output |

### 4.4 Component Mapping

| TS pi-tui Component | Haskell Widget | brick Primitive |
|---|---|---|
| `Box` | `HHTui.Widget.Box` | `hBox` / `vBox` / `vLimit` / `hLimit` |
| `Text` | `HHTui.Widget.Text` | `txt` / `txtWrap` |
| `Input` | `HHTui.Widget.Input` | Custom `Editor` widget with single-line mode |
| `Editor` | `HHTui.Widget.Editor` | Extend `Brick.Widgets.Edit.Editor` (multiline) |
| `SelectList` | `HHTui.Widget.SelectList` | `Brick.Widgets.List` with custom rendering |
| `Markdown` | `HHTui.Widget.Markdown` | Custom renderer (ANSI-colored, word-wrapped) |
| `Spacer` | `HHTui.Widget.Spacer` | `fill` / `padLeftRight` |
| `Loader` | `HHTui.Widget.Loader` | Spinner animation in `Widget` |
| `Image` | `HHTui.Widget.Image` | Raw escape sequence output via `vty` |
| `TruncatedText` | `HHTui.Widget.TruncatedText` | `visibleWidth` truncation on `txt` |
| Overlays (Modal) | `HHTui.Overlay` | Render layer in `appDraw` (priority ordering) |

### 4.5 Image and Terminal Protocol Support

The TypeScript pi-tui supports inline images (SIXEL, Kitty, iTerm2 protocols). This is the one area where `brick` has no built-in support. Implementation:

1. Query terminal capabilities on startup (like the TypeScript pi-tui's `terminal-image.ts`)
2. Store cell dimensions for aspect-ratio-correct rendering
3. Insert raw escape sequences into `vty` output using escape passthrough
4. `brick`'s `Widget` rendering can include raw `vty` image bytes interleaved with text content

### 4.6 Keybinding Configuration

The TypeScript pi-tui has a rich keybinding system (`keybindings.ts`) with per-action bindings, key conflicts, and user customization. Port this as `HHTui.Keybindings` integrating with `brick`'s event handling:

```haskell
data KeybindingsConfig = KeybindingsConfig
  { kbBindings :: Map ActionName [KeyId]
  , kbConflicts :: [KeyConflict]
  }

data KeyId = KeyId { keyText :: Text }
  deriving (Show, Eq, Ord)

matchesKey :: Vty.Event -> KeyId -> Bool
matchesKey (Vty.EvKey k mods) kid = ...
```

---

## 5. Package: `hharness-coding` — Coding Agent CLI & Extension System

This is the largest package. It ties everything together.

### 5.1 Core Architecture

```
hharness-coding/
  src/
    HHCoding/
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

Extensions are Haskell modules compiled into the binary. The `hharness-coding` package lists extension modules explicitly:

```haskell
-- In hharness-coding, built-in extensions are registered at startup
loadExtensions :: [ExtensionFactory] -> [FilePath] -> IO LoadExtensionsResult
loadExtensions builtIns paths = do
  -- builtIns are Haskell modules compiled into the binary
  -- paths point to .hs or .lua files that get loaded dynamically
  ...
```

A user's `.hharness/config.hs` or project's `.hharness/extensions/` directory can specify extension modules:

```haskell
-- ~/.hharness/extensions/my-extension.hs
module MyExtension where
import HHCoding.Agent.Extensions.Types

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
-- .hharness/extensions/hello.lua
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
-- HHCoding.Agent.Tools.Bash
createBashTool :: Maybe BashOperations -> FilePath -> AgentTool
createBashTool operations root = AgentTool { ... }

-- HHCoding.Agent.Tools.Read
createReadTool :: FilePath -> AgentTool

-- HHCoding.Agent.Tools.Edit
createEditTool :: FilePath -> AgentTool

-- HHCoding.Agent.Tools.Write
createWriteTool :: FilePath -> AgentTool

-- HHCoding.Agent.Tools.Grep
createGrepTool :: FilePath -> AgentTool

-- HHCoding.Agent.Tools.Find
createFindTool :: FilePath -> AgentTool

-- HHCoding.Agent.Tools.Ls
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

1. **Interactive** — Full TUI (uses `hharness-tui`)
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
hharness-ai
  ├── aeson, bytestring, text, containers, stm, async, time, vector
  ├── http-conduit, http-client-tls, http-types
  └── claude (MercuryTechnologies/claude), openai (MercuryTechnologies/openai)

hharness-agent
  └── hharness-ai, aeson, stm, async, containers, text, time

hharness-tui
  └── brick, vty, text, containers, stm, unix, bytestring, vector, microlens

hharness-coding
  └── hharness-agent, hharness-ai, hharness-tui, aeson, stm, async,
       directory, filepath, process, optparse-applicative,
       hs-lua (for Lua extensions), cryptonite, memory
```

---

## 7. Implementation Order

| Phase | Package | Milestone |
|---|---|---|
| **1** | `hharness-ai` | Types, EventStream, Anthropic provider (port `HHAgent.Claude`), API registry, Faux provider |
| **2** | `hharness-ai` | OpenAI provider (both completions and responses APIs using MercuryTechnologies/openai) |
| **3** | `hharness-agent` | Evolve existing: upgrade AgentTool, add QueueMode, onPayload/onResponse hooks, CustomMessage support |
| **4** | `hharness-tui` | Brick app skeleton, key handling, basic widgets (Box, Text, Input, SelectList) |
| **5** | `hharness-coding` | CLI skeleton, session manager, tools (bash, read, edit, write), system prompt builder |
| **6** | `hharness-coding` | Extension system (Types, Runner, Loader for compiled-in extensions) |
| **7** | `hharness-coding` | Lua extension backend, config loading, slash commands |
| **8** | `hharness-tui` | Advanced widgets (Markdown rendering, multiline Editor, autocomplete, overlays, images) |
| **9** | `hharness-coding` | Interactive mode (full TUI), compaction, model cycling |
| **10** | `hharness-coding` | RPC mode, print mode, authentication flows |

---

## 8. Testing Strategy

- **hharness-ai**: Unit tests for Anthropic and OpenAI provider request/response serialization. Integration tests against real APIs. The Faux provider is used for agent loop tests without API keys.
- **hharness-agent**: Property-based tests (QuickCheck) for the agent loop. Unit tests for state transitions.
- **hharness-tui**: Widget rendering and event handling tests using `brick`'s test infrastructure (`Brick.Test`) and `vty` image snapshots.
- **hharness-coding**: End-to-end tests with the `faux` provider (the hharness-ai Faux provider). Golden tests for session serialization.

### 8.1 End-to-End Multi-Turn Agent Testing

The agent loop is the most critical piece to test because it orchestrates streaming, tool execution, state mutation, and event emission across many turns. We test it without real API calls by building *scripted mock providers* — `StreamFn` implementations that inspect the accumulated context and return deterministic responses.

#### 8.1.1 Scripted Mock Provider Pattern

A scripted provider turns the `Context` (conversation history + tools) into a predetermined response sequence. This is more powerful than the single-response `fauxStreamFn` because it can simulate multi-turn tool-use conversations.

```haskell
-- | A scripted response: either plain text or a tool call request.
data ScriptStep
  = Say Text                           -- ^ assistant text response
  | Call Text Text Value               -- ^ tool name, callId, arguments
  | CallThenSay Text Text Value Text   -- ^ tool call + final text after result
  | Err Text                           -- ^ provider error

-- | Build a StreamFn from a list of steps.  Steps are consumed in order.
scriptedStreamFn :: IORef [ScriptStep] -> StreamFn
scriptedStreamFn stepsRef _model ctx _opts = do
  es <- newEventStream
  _ <- async $ do
      ts <- nowMs
      steps <- readIORef stepsRef
      case steps of
        [] -> pushDone es ts []
        (step : rest) -> do
          writeIORef stepsRef rest
          case step of
            Say txt -> streamText es ts txt
            Call name callId args -> streamToolCall es ts name callId args
            CallThenSay name callId args txt -> streamToolThenText es ts name callId args txt
            Err msg -> streamError es ts msg
  pure es
```

Key helper: `streamToolThenText` emits `EvToolCallStart` / `EvToolCallDelta` / `EvToolCallEnd` for the tool call, then immediately switches to text and finishes with `StopEndTurn`. This tests the real streaming path where a model can interleave reasoning, tool calls, and output text.

#### 8.1.2 Test Scenarios

| Scenario | Script | Assertions |
|---|---|---|
| **Single turn, no tools** | `[Say "hello"]` | Event sequence: `agent_start` → `turn_start` → `message_start` (user) → `message_end` (user) → `message_start` (assistant) → `message_update` … → `message_end` → `turn_end` → `agent_end`. Final messages: 2 (user + assistant). |
| **Single turn, one tool call** | `[Call "bash" "tc1" (object ["command" .= "ls"])]` | Events include `tool_exec_start tc1 bash`, `tool_exec_end tc1 bash … False`. Final messages: 3 (user + assistant + toolResult). Tool is actually executed via `atExecute`. |
| **Tool then final text** | `[CallThenSay "bash" "tc1" args "Done"]` | Assistant message has `StopToolUse`. After tool result is appended, a *second* assistant message is generated with `StopEndTurn` containing "Done". |
| **Sequential vs Parallel** | `[Call "a" "1" args, Call "b" "2" args]` | With `Sequential`: `tool_exec_start 1` → `tool_exec_end 1` → `tool_exec_start 2` → `tool_exec_end 2`. With `Parallel`: both `tool_exec_start` fire before any `tool_exec_end`. |
| **Steering injection** | `[Say "ack"]` + mid-run `steer agent (UserMessage …)` | `steer` enqueues a user message. Loop emits `turn_start` again, user message events, then a *new* assistant response. Verify `getState` shows 4 messages total. |
| **Follow-up after stop** | `[Say "first"]` + `followUp agent (UserMessage …)` | After first `agent_end`, follow-up triggers a second run. Verify two full `agent_start` … `agent_end` sequences in event log. |
| **Tool error → retry** | `[Call "crash" "tc1" args]` where tool throws | `tool_exec_end` carries `isError=True`. `afterToolCall` hook can mutate error to success or leave it. Verify `_errorMsg` in `AgentSnapshot`. |
| **Cancel mid-stream** | `[Say "long"]` (slow provider) + `abort agent` | `cancel` check fires; verify `snapIsStreaming` becomes `False` and `_errorMsg` is set. |
| **beforeToolCall blocking** | `[Call "bash" "tc1" args]` + hook returns `BlockCall` | Tool is never executed. A `ToolResultMessage` with `isError=True` and the block reason is appended instead. |
| **Invalid tool args** | `[Call "bash" "tc1" (object ["bad" .= True])]` | `atValidateArgs` returns `Left`. Same error path as blocked call — tool result with `isError=True`. |
| **Context transform** | `[Say "hello"]` with `alcTransformContext` that drops user messages | Verify `alcConvertToLlm` does *not* receive the dropped message, but the `Agent` still accumulates it in `_messages`. |
| **Empty continue** | `[Say "hi"]` then `continue agent` | `runAgentLoopContinue` starts from existing context. Second assistant message is added. Verify 3 total messages. |

#### 8.1.3 Event Invariants (Property-Based)

Use `QuickCheck` to generate random agent scripts and assert invariants that must hold for *every* run:

1. **Every `message_start` has a matching `message_end`.**
2. **Every `tool_exec_start` has a matching `tool_exec_end`.**
3. **`turn_end` can only follow a `message_end` (assistant).**
4. **No `message_update` after `message_end` for the same message index.**
5. **`agent_end` is always the last event.**
6. **Tool count in a turn matches `length` of `EvTurnEnd` tool-result list.**
7. **Parallel mode: all `tool_exec_start` timestamps ≤ all `tool_exec_end` timestamps for that turn.**

Invariant-checking function: fold over `EventStream` or `[AgentEvent]` into a small state machine tracking open scopes (`message`, `tool`, `turn`).

```haskell
checkInvariants :: [AgentEvent] -> Either InvariantViolation ()
-- ^ Left if any invariant is broken.
```

#### 8.1.4 Integration-Style Test with Real `Agent`

Rather than calling `runAgentLoop` directly, exercise the public `Agent` API end-to-end:

```haskell
it "multi-turn tool conversation" $ do
  let script =
        [ Call "echo" "tc1" (object ["text" .= "ping"])
        , CallThenSay "echo" "tc2" (object ["text" .= "pong"]) "All done"
        ]
  stepsRef <- newIORef script
  let opts = (defaultAgentOptions testModel (scriptedStreamFn stepsRef))
               { aoTools = [echoTool] }
  agent <- newAgent opts

  -- Turn 1: user asks something; assistant calls echo
  promptText agent "Say ping"
  waitForIdle agent
  snap1 <- getState agent
  length (snapMessages snap1) `shouldBe` 3  -- user + assistant + toolResult

  -- Continue: assistant now calls echo again and says "All done"
  continue agent
  waitForIdle agent
  snap2 <- getState agent
  length (snapMessages snap2) `shouldBe` 6    -- + assistant + toolResult + assistant

  -- Event log invariants
  events <- readIORef eventsRef
  checkInvariants events `shouldBe` Right ()
```

#### 8.1.5 Where These Tests Live

| Package | Module | Focus |
|---|---|---|
| `hharness-agent` | `test/AgentLoopSpec.hs` | Low-level `runAgentLoop` / `runAgentLoopContinue` with scripted `StreamFn`. |
| `hharness-agent` | `test/AgentSpec.hs` | High-level `Agent` API: `prompt`, `steer`, `followUp`, `abort`, `continue`, snapshots, subscribers. |
| `hharness-agent` | `test/Invariants.hs` | Reusable event-log invariant checker, used by both suites. |
| `hharness-ai` | `test/FauxProviderSpec.hs` | `fauxStreamFn` emits correct event shape and final `AssistantMessage`. |
| `hharness-ai` | `test/AnthropicSpec.hs` | Request/response JSON round-trip tests; compat JSON patching. |

---


### 8.2 End-to-End Testing with Local Ollama Models

Ollama exposes an OpenAI-compatible API at `POST /v1/chat/completions`. Some wrappers also provide an Anthropic-compatible facade. Rather than writing a dedicated Ollama provider, we **reuse the existing `openai-completions` or `anthropic-messages` provider** and override the `baseUrl` to `http://localhost:11434/v1` (or whatever the user has in `$HOME/.pi/agent/models.json`).

#### 8.2.1 Model Registry from Disk (`HHAi.Models.Json`)

The user\'s `$HOME/.pi/agent/models.json` specifies provider configuration and model metadata:

```json
{
  "providers": {
    "ollama": {
      "api": "openai-completions",
      "apiKey": "ollama",
      "baseUrl": "http://localhost:11434/v1",
      "models": [
        { "id": "qwen2.5:14b", "contextWindow": 32768, "input": ["text"], "reasoning": false },
        { "id": "llama3.1:8b", "contextWindow": 128000, "input": ["text", "image"], "reasoning": false }
      ]
    }
  }
}
```

A loader module parses this into `HHAi.Types.Model` records, inheriting `api`, `apiKey`, and `baseUrl` from the provider stanza:

```haskell
module HHAi.Models.Json (
  loadModelsFromFile,
  loadUserModels,
) where

data ProviderConfig = ProviderConfig
  { pcApi    :: Text
  , pcApiKey :: Text
  , pcBaseUrl :: Text
  , pcModels :: [ModelStub]
  }

data ModelStub = ModelStub
  { msId            :: Text
  , msContextWindow :: Int
  , msInput         :: [Text]
  , msReasoning     :: Bool
  }

providerModels :: Text -> ProviderConfig -> [Model]
providerModels providerName pc =
  [ Model
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
  | m <- pcModels pc
  ]
```

`loadUserModels` reads `$HOME/.pi/agent/models.json` and appends the loaded entries to the built-in model list. If the file is missing, fall back to `defaultAnthropicModels <> defaultOpenAIModels`.

#### 8.2.2 Wrapping a Provider with Request/Response Logging

For end-to-end debugging we need a **trace log** of every HTTP request sent to the local model and every SSE event received back. The log is append-only JSONL (`*.jsonl`) with one JSON object per line.

```haskell
module HHAi.Provider.Logging (
  withRequestResponseLogging,
) where

import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))

data LogEntry
  = LogRequest  { lTimestamp :: Int64, lModelId :: Text, lUrl :: Text, lBody :: Value }
  | LogResponse { lTimestamp :: Int64, lModelId :: Text, lEventType :: Text, lPayload :: Value }
  | LogError    { lTimestamp :: Int64, lModelId :: Text, lMessage :: Text }
  deriving (Generic)
```

The wrapper intercepts at the `StreamFn` layer, *before* the request is serialised:

```haskell
withRequestResponseLogging :: FilePath -> StreamFn -> StreamFn
withRequestResponseLogging logPath baseFn model ctx opts = do
  t0 <- nowMs
  ensureLogDir logPath
  -- Log the outgoing request context
  appendJsonl logPath $ LogRequest t0 (mId model) (mBaseUrl model) (contextToValue ctx)
  -- Run the real provider
  es <- baseFn model ctx opts
  -- Fork a forwarding thread that copies every event into the log
  es' <- newEventStream
  _ <- async $ do
    let loop = do
          mev <- nextEvent es
          case mev of
            Nothing -> do
              res <- getResult es
              case res of
                Right msg -> appendJsonl logPath $ LogResponse (amTimestamp msg) (mId model) "done" (toJSON msg)
                Left e    -> appendJsonl logPath $ LogError (amTimestamp msg) (mId model) (Text.pack $ show e)
              endStream es' res
            Just ev -> do
              appendJsonl logPath $ LogResponse t0 (mId model) (eventType ev) (toJSON ev)
              pushEvent es' ev
              loop
    loop
  pure es'
```

The JSONL log is human-readable and can be replayed into the test suite as a golden file or used for prompt engineering:

```jsonl
{"tag":"request","timestamp":1234567890000,"modelId":"qwen2.5:14b","url":"http://localhost:11434/v1/chat/completions","body":{"messages":[{"role":"user","content":"Say ping"}],"stream":true}}
{"tag":"response","timestamp":1234567900000,"modelId":"qwen2.5:14b","eventType":"text_delta","payload":{"text":"pong"}}
{"tag":"response","timestamp":1234567910000,"modelId":"qwen2.5:14b","eventType":"done","payload":{"stopReason":"end_turn"}}
```

#### 8.2.3 Multi-Turn Test Harness (`test/OllamaE2ESpec.hs`)

A standalone hspec suite that exercises the full stack against a locally running Ollama instance. The test is **conditional**: if `localhost:11434` does not respond, the spec is skipped.

```haskell
module OllamaE2ESpec (spec) where

import HHAi.Models.Json (loadUserModels)
import HHAi.Provider.Logging (withRequestResponseLogging)
import HHAi.Registry (newRegistry, getApiProvider, registerApiProvider)

spec :: Spec
spec = do
  describe "Ollama multi-turn" $ do
    it "loads models from ~/.pi/agent/models.json" $ do
      models <- loadUserModels
      any ((== "qwen2.5:14b") . mId) models `shouldBe` True

    it "runs a two-turn conversation and logs to JSONL" $ do
      -- 1. Discover local model
      models <- loadUserModels
      let model = fromJust $ find ((== "qwen2.5:14b") . mId) models

      -- 2. Resolve provider by mApi (e.g. "openai-completions")
      registry <- newRegistry
      registerOpenAI registry   -- provides both completions & responses
      provider <- fromJust <$> getApiProvider registry (mApi model)

      -- 3. Wrap provider with request/response logging
      logDir <- getTemporaryDirectory
      let logFile = logDir </> "hharness-ollama-" <> show (amTimestamp model) <> ".jsonl"
      let streamFn = withRequestResponseLogging logFile (apStream provider)

      -- 4. Build agent with a simple tool
      let opts = (defaultAgentOptions model streamFn)
                   { aoTools = [echoTool, weatherTool]
                   , aoToolExecution = Parallel
                   }
      agent <- newAgent opts

      -- 5. Turn 1: ask the model to use a tool
      promptText agent "What is the weather in Tokyo? Use the weather tool."
      waitForIdle agent

      -- 6. Verify tool was called
      snap1 <- getState agent
      length (filter isToolResult (snapMessages snap1)) `shouldBe` 1

      -- 7. Turn 2: continue the conversation
      promptText agent "Now what about Paris?"
      waitForIdle agent

      -- 8. Final assertions
      snap2 <- getState agent
      length (snapMessages snap2) `shouldSatisfy` (\>= 5)
      snapIsStreaming snap2 `shouldBe` False

      -- 9. Verify JSONL log exists and is valid
      logExists <- doesFileExist logFile
      logExists `shouldBe` True
      logLines <- Text.lines <$> Text.readFile logFile
      all isValidJson logLines `shouldBe` True
      length logLines `shouldSatisfy` (\>= 4)  -- request + at least 3 response events
```

**What this tests end-to-end**:
| Layer | Assertion |
|---|---|
| **Model loading** | `models.json` parses, `baseUrl` is local |
| **Provider routing** | `getApiProvider registry (mApi model)` resolves to OpenAI provider |
| **HTTP + SSE** | Real streaming response from `localhost:11434` |
| **Tool calling** | Assistant generates a `ToolCall`; agent loop executes `weatherTool` |
| **Multi-turn** | Second user prompt appends to existing context, model answers with history |
| **Event invariants** | `checkInvariants` on the collected `AgentEvent` list still passes |
| **Logging** | Every request and every streamed event appears in the JSONL file |

#### 8.2.4 Alternative: Anthropic-Compatible Local Wrappers

Some Ollama front-ends (e.g. `ollama` with a proxy layer) speak the Anthropic Messages API instead of OpenAI. In that case the user sets `"api": "anthropic-messages"` in `models.json` and the `anthropicStreamFn` / `anthropicStreamFnCompat` providers work unchanged -- only the `baseUrl` changes to `http://localhost:11434`.

The test harness remains identical: it reads `mApi` from the model record and looks up the provider in the registry. No code changes are required to switch between OpenAI- and Anthropic-compatible local models.

#### 8.2.5 Where the New Modules Live

| Package | Module | Purpose |
|---|---|---|
| `hharness-ai` | `HHAi.Models.Json` | Parse `$HOME/.pi/agent/models.json` into `[Model]` |
| `hharness-ai` | `HHAi.Provider.Logging` | `StreamFn` wrapper that writes request/response JSONL |
| `hharness-agent` | `test/OllamaE2ESpec.hs` | Integration test against local Ollama (skipped when offline) |
| `hharness-coding` | (future) CLI flag `--log-dir` | User-facing switch to enable request/response tracing |
