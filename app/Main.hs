{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Main where

import           Control.Concurrent         (threadDelay)
import           Control.Concurrent.Async   (mapConcurrently_)
import           Control.Exception          (IOException, catch)
import           Control.Monad              (forever, void)
import qualified Data.ByteString.Lazy       as BL
import qualified Data.ByteString.Lazy.Char8 as BC
import qualified Data.Map.Strict            as Map
import           Data.Maybe                 (fromJust)
import           Data.Semigroup             ((<>))
import           Data.Text                  (Text, isSuffixOf, pack, unpack)
import           Network.API.Pushover
import           Network.MQTT.Client
import           Network.URI
import           Options.Applicative        (Parser, execParser, fullDesc, help,
                                             helper, info, long, maybeReader,
                                             option, progDesc, showDefault,
                                             strOption, value, (<**>))
import           System.Log.Logger          (Priority (INFO), errorM, infoM,
                                             rootLoggerName, setLevel,
                                             updateGlobalLogger)


import           Babyconf
import           Babysitter

data Options = Options {
  optMQTTURL         :: URI
  , optMQTTLWTTopic  :: Maybe Text
  , optMQTTLWTMsg    :: Maybe BL.ByteString
  , optPushoverToken :: Text
  , optPushoverUser  :: Text
  , optConfFile      :: String
  }

options :: Parser Options
options = Options
  <$> option (maybeReader $ parseURI) (long "mqtt-uri" <> showDefault <> value (fromJust $ parseURI "mqtt://test.mosquitto.org/#babysitter") <> help "mqtt broker URI")
  <*> option mt (long "mqtt-lwt-topic" <> showDefault <> value Nothing <> help "mqtt last will topic")
  <*> option mb (long "mqtt-lwt-msg" <> showDefault <> value Nothing <> help "mqtt last will message")
  <*> strOption (long "pushover-token" <> showDefault <> value "" <> help "pushover token")
  <*> strOption (long "pushover-user" <> showDefault <> value "" <> help "pushover user")
  <*> strOption (long "conf" <> showDefault <> value "baby.conf" <> help "config file")

  where
    mt = maybeReader $ pure.pure.pack
    mb = maybeReader $ pure.pure . BC.pack

timedout :: PushoverConf -> Action -> MQTTClient -> Event -> Text -> IO ()

-- Setting values.
timedout _ (ActSet t m r) mc ev topic = do
  infoM rootLoggerName $ unpack topic <> " - " <> show ev <> " -> set " <> unpack t
  to ev
    where
      to TimedOut = publishq mc t m r QoS2
      to _        = pure ()

-- Alerting via pushover.
timedout (PushoverConf tok umap) (ActAlert users) _ ev topic = do
  infoM rootLoggerName $ unpack topic <> " - " <> show ev <> " -> " <> show users
  to ev

    where
      to TimedOut = do
        mapM_ (\usr -> let m = (message tok usr (topic <> " timed out"))
                               {_title="Babysitter:  Timed Out"} in
                         void $ sendMessage m) users'
      to Returned = do
        mapM_ (\usr -> let m = (message tok usr (topic <> " came back"))
                               {_title="Babysitter:  Came Back"} in
                         void $ sendMessage m) users'
      to _ = pure ()

      users' = map (umap Map.!) users

connectMQTT :: URI -> Maybe Text -> Maybe BL.ByteString -> (MQTTClient -> Text -> BL.ByteString -> IO ()) -> IO MQTTClient
connectMQTT uri lwtTopic lwtMsg f = do
  let cf = case uriScheme uri of
             "mqtt:"  -> runClient
             "mqtts:" -> runClientTLS
             us       -> fail $ "invalid URI scheme: " <> us

      (Just a) = uriAuthority uri
      (u,p) = up (uriUserInfo a)

  cf mqttConfig{_hostname=uriRegName a, _port=port (uriPort a) (uriScheme uri), _connID=cid (uriFragment uri),
                _cleanSession=True,
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

withMQTT :: URI -> Maybe Text -> Maybe BL.ByteString -> (MQTTClient -> Text -> BL.ByteString -> IO ()) -> (MQTTClient -> IO ()) -> IO ()
withMQTT u mlwtt mlwtm cb f = do
  mc <- connectMQTT u mlwtt mlwtm cb
  f mc
  r <- waitForClient mc
  infoM rootLoggerName $ mconcat ["Disconnected from ", show u, " ", show r]

runWatcher :: PushoverConf -> Source -> IO ()
runWatcher pc (Source (u,mlwtt,mlwtm) watches) = do
  let things = map (\(Watch t i action) -> (t, (i, timedout pc action))) watches
  wd <- mkWatchDogs (topicMatch (minutes 60, undefined) things)
  feedStartup wd undefined watches

  forever $ do
    catch (withMQTT u mlwtt mlwtm (\c t _ -> feed wd t c) (subAndWait things)) (
      \e -> errorM rootLoggerName $ mconcat ["connection to  ", show u, ": ",
                                             show (e :: IOException)])

    threadDelay (seconds 5)

    where
      -- Feed all the non-wildcarded watches to the watch dog so
      -- timeouts are meaningful from zero state.
      feedStartup _ _ [] = pure ()
      feedStartup wd mc (Watch t _ _:xs)
        | "#" `isSuffixOf` t = feedStartup wd mc xs
        | otherwise          = feed wd t mc >> feedStartup wd mc xs

      subAndWait things mc = do
        infoM rootLoggerName $ mconcat ["Subscribing at ", show u, " - ", show [(t,QoS2) | (t,_) <- things]]
        subrv <- subscribe mc [(t,QoS2) | (t,_) <- things]
        infoM rootLoggerName $ mconcat ["Sub response from ", show u, ": ", show subrv]

run :: Options -> IO ()
run Options{..} = do
  (Babyconf dests srcs) <- parseConfFile optConfFile
  mapConcurrently_ (runWatcher dests) srcs

main :: IO ()
main = do
  updateGlobalLogger rootLoggerName (setLevel INFO)
  (run =<< execParser opts)

  where opts = info (options <**> helper)
          ( fullDesc <> progDesc "Watch the things.")
