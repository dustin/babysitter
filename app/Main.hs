{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Main where

import           Control.Monad              (void)
import qualified Data.ByteString.Lazy       as BL
import qualified Data.ByteString.Lazy.Char8 as BC
import           Data.Semigroup             ((<>))
import           Data.Text                  (Text, pack, unpack)
import           Network.API.Pushover
import           Network.MQTT.Client
import           Options.Applicative        (Parser, auto, execParser, fullDesc,
                                             help, helper, info, long,
                                             maybeReader, option, progDesc,
                                             showDefault, strOption, value,
                                             (<**>))
import           System.Log.Logger          (Priority (INFO), infoM,
                                             rootLoggerName, setLevel,
                                             updateGlobalLogger)


import           Babysitter

data Options = Options {
  optMQTTHost        :: String
  , optMQTTPort      :: Int
  , optMQTTConnID    :: String
  , optMQTTUsername  :: Maybe String
  , optMQTTPassword  :: Maybe String
  , optMQTTLWTTopic  :: Maybe Text
  , optMQTTLWTMsg    :: Maybe BL.ByteString
  , optPushoverToken :: Text
  , optPushoverUser  :: Text
  }

options :: Parser Options
options = Options
  <$> strOption (long "mqtt-host" <> showDefault <> value "test.mosquitto.org" <> help "mqtt broker address")
  <*> option auto (long "mqtt-port" <> showDefault <> value 8883 <> help "mqtt broker port")
  <*> strOption (long "mqtt-connid" <> showDefault <> value "babysitter" <> help "mqtt connection ID")
  <*> option ms (long "mqtt-username" <> showDefault <> value Nothing <> help "mqtt username")
  <*> option ms (long "mqtt-password" <> showDefault <> value Nothing <> help "mqtt password")
  <*> option mt (long "mqtt-lwt-topic" <> showDefault <> value Nothing <> help "mqtt last will topic")
  <*> option mb (long "mqtt-lwt-msg" <> showDefault <> value Nothing <> help "mqtt last will message")
  <*> strOption (long "pushover-token" <> showDefault <> value "" <> help "pushover token")
  <*> strOption (long "pushover-user" <> showDefault <> value "" <> help "pushover user")

  where
    mt = maybeReader $ pure.pure.pack
    ms = maybeReader $ pure.pure
    mb = maybeReader $ pure.pure . BC.pack

timedout :: Options -> Text -> Event -> Text -> IO ()
timedout Options{..} site ev topic = do
  infoM (unpack site) $ unpack topic <> " - " <> show ev
  to ev

    where
      to TimedOut = do
        let tok = optPushoverToken
            usr = optPushoverUser
            m = (message tok usr (topic <> " timed out"))
                {_title="Babysitter:  Timed Out"}
        void $ sendMessage m
      to Returned = do
        let tok = optPushoverToken
            usr = optPushoverUser
            m = (message tok usr (topic <> " came back"))
                {_title="Babysitter:  Came Back"}
        void $ sendMessage m
      to _ = pure ()

run :: Options -> IO ()
run o@Options{..} = do
  let things = [("oro/#", (minutes 15, timedout o "oro")),
                ("sj/#", (minutes 5, timedout o "sj"))]

  wd <- mkWatchDogs (topicMatch (minutes 60, timedout o "def") things)

  mc <- runClientTLS mqttConfig{_hostname=optMQTTHost, _port=optMQTTPort, _connID=optMQTTConnID,
                                _cleanSession=False,
                                _username=optMQTTUsername, _password=optMQTTPassword,
                                _lwt=mkLWT <$> optMQTTLWTTopic <*> optMQTTLWTMsg <*> Just False,
                                _msgCB=Just $ const . feed wd}

  -- Probably want to verify these...
  _ <- subscribe mc [(t,QoS2) | (t,_) <- things]

  print =<< waitForClient mc


main :: IO ()
main = do
  updateGlobalLogger rootLoggerName (setLevel INFO)
  (run =<< execParser opts)

  where opts = info (options <**> helper)
          ( fullDesc <> progDesc "Watch the things.")
