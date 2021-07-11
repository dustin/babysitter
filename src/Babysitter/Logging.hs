{-# LANGUAGE OverloadedStrings #-}

module Babysitter.Logging where


import           Control.Monad.Logger    (LogLevel (..), MonadLogger, ToLogStr (..), logWithoutLoc, toLogStr)

logAt :: (MonadLogger m, ToLogStr msg) => LogLevel -> msg -> m ()
logAt l = logWithoutLoc "" l . toLogStr

logErr :: (MonadLogger m, ToLogStr msg) => msg -> m ()
logErr = logAt LevelError

logInfo :: (MonadLogger m, ToLogStr msg) => msg -> m ()
logInfo = logAt LevelInfo

logDbg :: (MonadLogger m, ToLogStr msg) => msg -> m ()
logDbg = logAt LevelDebug
