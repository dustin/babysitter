{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Main where

import           Control.Monad              (void)
import qualified Data.ByteString.Lazy       as BL
import qualified Data.ByteString.Lazy.Char8 as BC
import           Data.Maybe                 (fromJust)
import           Data.Semigroup             ((<>))
import           Data.Text                  (Text, pack, unpack)
import           Network.API.Pushover
import           Network.MQTT.Client
import           Network.URI
import           Options.Applicative        (Parser, execParser, fullDesc, help,
                                             helper, info, long, maybeReader,
                                             option, progDesc, showDefault,
                                             strOption, value, (<**>))
import           System.Log.Logger          (Priority (INFO), infoM,
                                             rootLoggerName, setLevel,
                                             updateGlobalLogger)


import           Babysitter

data Options = Options {
  optMQTTURL         :: URI
  , optMQTTLWTTopic  :: Maybe Text
  , optMQTTLWTMsg    :: Maybe BL.ByteString
  , optPushoverToken :: Text
  , optPushoverUser  :: Text
  }

options :: Parser Options
options = Options
  <$> option (maybeReader $ parseURI) (long "mqtt-uri" <> showDefault <> value (fromJust $ parseURI "mqtt://test.mosquitto.org/#babysitter") <> help "mqtt broker URI")
  <*> option mt (long "mqtt-lwt-topic" <> showDefault <> value Nothing <> help "mqtt last will topic")
  <*> option mb (long "mqtt-lwt-msg" <> showDefault <> value Nothing <> help "mqtt last will message")
  <*> strOption (long "pushover-token" <> showDefault <> value "" <> help "pushover token")
  <*> strOption (long "pushover-user" <> showDefault <> value "" <> help "pushover user")

  where
    mt = maybeReader $ pure.pure.pack
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

connectMQTT :: URI -> Maybe Text -> Maybe BL.ByteString -> (Text -> BL.ByteString -> IO ()) -> IO MQTTClient
connectMQTT uri lwtTopic lwtMsg f = do
  let cf = case uriScheme uri of
             "mqtt:"  -> runClient
             "mqtts:" -> runClientTLS
             us       -> fail $ "invalid URI scheme: " <> us

      (Just a) = uriAuthority uri
      (u,p) = up (uriUserInfo a)

  cf mqttConfig{_hostname=uriRegName a, _port=port (uriPort a) (uriScheme uri), _connID=cid (uriFragment uri),
                _cleanSession=False,
                _username=u, _password=p,
                _lwt=mkLWT <$> lwtTopic <*> lwtMsg <*> Just False,
                _msgCB=Just $ f}

  where
    port "" "mqtt:"  = 1883
    port "" "mqtts:" = 8883
    port x _         = read x

    cid ('#':[]) = "babysitter"
    cid ('#':xs) = xs
    cid _        = "babysitter"

    up "" = (Nothing, Nothing)
    up x = let (u,r) = break (== ':') (init x) in
             (Just (unEscapeString u), if r == "" then Nothing else Just (unEscapeString $ tail r))

run :: Options -> IO ()
run o@Options{..} = do
  let things = [("oro/#", (minutes 15, timedout o "oro")),
                ("sj/#", (minutes 5, timedout o "sj"))]

  wd <- mkWatchDogs (topicMatch (minutes 60, timedout o "def") things)

  mc <- connectMQTT optMQTTURL optMQTTLWTTopic optMQTTLWTMsg (const . feed wd)

  -- Probably want to verify these...
  _ <- subscribe mc [(t,QoS2) | (t,_) <- things]

  print =<< waitForClient mc


main :: IO ()
main = do
  updateGlobalLogger rootLoggerName (setLevel INFO)
  (run =<< execParser opts)

  where opts = info (options <**> helper)
          ( fullDesc <> progDesc "Watch the things.")
