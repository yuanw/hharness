{- | STM-backed event stream.

Equivalent to @EventStream<Event, Result>@ in the TypeScript source:
an async sequence of events that eventually settles with a final result.

Thread-safe: multiple producers may call 'pushEvent' concurrently.
Single-consumer: only one thread should call 'nextEvent'/'foldStream'.
-}
module HHAi.Stream (
  EventStream,
  newEventStream,
  pushEvent,
  endStream,
  nextEvent,
  getResult,
  foldStream,
) where

import Control.Concurrent.STM
import Control.Exception (SomeException, throwIO)
import Control.Monad (void)

{- | An asynchronous, single-consumer event stream.

Internally, events are enqueued as @Just event@ and stream termination is
signalled by @Nothing@.  The final result is placed in a 'TMVar' once the
stream ends.
-}
data EventStream event result = EventStream
  { _esQueue :: TQueue (Maybe event)
  , _esResult :: TMVar (Either SomeException result)
  }

-- | Allocate a new, empty event stream.
newEventStream :: IO (EventStream event result)
newEventStream = EventStream <$> newTQueueIO <*> newEmptyTMVarIO

-- | Enqueue an event.  Non-blocking.
pushEvent :: EventStream event result -> event -> IO ()
pushEvent es ev = atomically $ writeTQueue (_esQueue es) (Just ev)

{- | Signal end-of-stream and deliver the final result.
Idempotent: safe to call more than once (subsequent calls are ignored).
-}
endStream :: EventStream event result -> result -> IO ()
endStream es r = atomically $ do
  writeTQueue (_esQueue es) Nothing
  void $ tryPutTMVar (_esResult es) (Right r)

{- | Read the next event.  Blocks until one is available.
Returns 'Nothing' once the stream has ended.
-}
nextEvent :: EventStream event result -> IO (Maybe event)
nextEvent es = atomically $ readTQueue (_esQueue es)

{- | Block until the final result is available and return it.
Rethrows any exception stored by the producer.
-}
getResult :: EventStream event result -> IO result
getResult es =
  atomically (readTMVar (_esResult es)) >>= \case
    Left e -> throwIO e
    Right r -> pure r

-- | Consume all events by calling @handler@ for each, then return the result.
foldStream :: EventStream event result -> (event -> IO ()) -> IO result
foldStream es handler = go
  where
    go =
      nextEvent es >>= \case
        Nothing -> getResult es
        Just ev -> handler ev >> go
