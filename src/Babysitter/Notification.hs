{-# LANGUAGE OverloadedStrings, TypeApplications #-}
{-# LANGUAGE DeriveGeneric     #-}

module Babysitter.Notification where

import           Control.Lens
import           Control.Monad          (void, unless)
import           Control.Monad.IO.Class (MonadIO (..))
import qualified Data.Aeson             as J
import           Data.Text (Text, pack)
import           Control.Monad.Catch        (MonadCatch(..), catch, SomeException(..))
import           Network.API.Pushover   (_title, message, sendMessage)
import           Network.Wreq
import           Network.Wreq.Types     (Postable)
import           Generics.Deriving.Base       (Generic)
import           Control.Monad.Logger    (MonadLogger)
import           Data.Char (toLower)

import           Babyconf
import           Babysitter.Types
import           Babysitter.Logging

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

jpost :: (MonadIO m, Postable a, J.FromJSON r) => String -> a -> m r
jpost u v = view responseBody <$> liftIO (post u v >>= asJSON)

data PagerRes = PagerRes {
  _pageResStatus :: Text
  , _pageResMessage :: Text
  } deriving (Show, Generic)

instance J.FromJSON PagerRes where
  parseJSON = J.genericParseJSON J.defaultOptions{ J.fieldLabelModifier = fmap toLower . drop 8 }

notifyPagerDuty :: (MonadCatch m, MonadLogger m, MonadIO m) => Event -> ServiceKey -> Text -> m ()
notifyPagerDuty ev sk topic = do
  res <- send `catch` failed
  unless (_pageResStatus res == "success") $ logErr (show res)

    where
      send = jpost "https://events.pagerduty.com/generic/2010-04-15/create_event.json" (J.encode msg)

      et TimedOut = "trigger"
      et Returned = "resolve"
      et Created  = error "we do not notify on created"

      failed (SomeException e) = pure $ PagerRes "failed" (pack (show e))

      msg = J.Object (mempty & at "service_key" ?~ J.String sk
                      & at "event_type" ?~ J.String (et ev)
                      & at "description" ?~ J.String (topic <> " timed out")
                      & at "incident_key" ?~ J.String topic
                      & at "client" ?~ J.String "babysitter")
