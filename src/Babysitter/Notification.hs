{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}

module Babysitter.Notification where

import           Control.Monad                 (void)
import           Control.Monad.Catch           (MonadCatch (..))
import           Control.Monad.IO.Class        (MonadIO (..))
import           Control.Monad.Logger          (MonadLogger)
import           Data.Text                     (Text, unpack)
import qualified Network.API.PagerDuty.EventV1 as PD
import           Network.API.Pushover          (_title, message, sendMessage)

import           Babyconf
import           Babysitter.Logging
import           Babysitter.Types

notify :: (MonadCatch m, MonadLogger m, MonadIO m) => Event -> Destination -> Text -> m ()

notify ev (Pushover tok usr) topic = liftIO . void . sendMessage $ m
  where
    m = (message tok usr (topic <> bsuf ev)) {_title=title ev}
    bsuf TimedOut = " timed out"
    bsuf Returned = " came back"
    bsuf _        = ""
    title TimedOut = "Babysitter: Timed Out"
    title Returned = "Babysitter: Came Back"
    title Created  = "Babysitter: Created"

notify ev (PagerDuty k) topic = notifyPagerDuty ev k topic

notifyPagerDuty :: (MonadCatch m, MonadLogger m, MonadIO m) => Event -> ServiceKey -> Text -> m ()
notifyPagerDuty ev sk topic = deliver ev >>= report

    where
      report (PD.Success _)   = pure ()
      report (PD.Failure s m) = logErr ("pagerduty failed: " <> unpack s <> ": " <> unpack m)

      deliver TimedOut = do
        let event = PD.TriggerEvent {
              PD._teServiceKey=sk
              , PD._teIncidentKey=Just topic
              , PD._teDescription=topic <> " timed out"
              , PD._teClient="babysitter"
              , PD._teClientURL="https://github.com/dustin/babysitter"
              , PD._teDetails = Nothing
              , PD._teContexts=[]}
        PD.deliver (event :: PD.TriggerEvent')

      deliver Returned = do
        let event = PD.UpdateEvent {
              PD._updateServiceKey=sk
              , PD._updateType=PD.Resolve
              , PD._updateIncidentKey=topic
              , PD._updateDescription=topic <> " returned"
              , PD._updateDetails = Nothing}
        PD.deliver (event :: PD.UpdateEvent')

      deliver Created  = pure $ PD.Failure "invalid event" "we do not notify on Created events"
