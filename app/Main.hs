{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Main where

import           Control.Concurrent         (threadDelay)
import           Control.Concurrent.Async   (mapConcurrently_)
import           Control.Exception          (SomeException, bracket, catch)
import           Control.Lens               ((&), (.~))
import           Control.Monad              (forever, mapM, void, when)
import qualified Data.ByteString.Lazy       as BL
import qualified Data.ByteString.Lazy.Char8 as BC
import           Data.HashMap.Strict        (HashMap)
import qualified Data.HashMap.Strict        as HM
import           Data.List                  (partition)
import           Data.Map.Strict            (Map)
import qualified Data.Map.Strict            as Map
import           Data.Maybe                 (fromJust)
import           Data.Semigroup             ((<>))
import           Data.String                (fromString)
import           Data.Text                  (Text, concat, intercalate,
                                             isInfixOf, isSuffixOf, pack,
                                             unpack)
import qualified Data.Text.Encoding         as TE
import           Data.Time
import qualified Data.Vector                as V
import           Database.InfluxDB          as IDB
import           Network.API.Pushover       (message, sendMessage, _body,
                                             _title)
import           Network.MQTT.Client
import           Network.MQTT.Topic         (match)
import           Network.URI
import           Options.Applicative        (Parser, auto, execParser, fullDesc,
                                             help, helper, info, long,
                                             maybeReader, option, progDesc,
                                             showDefault, strOption, value,
                                             (<**>))
import           System.Log.Logger          (Priority (INFO), errorM, infoM,
                                             rootLoggerName, setLevel,
                                             updateGlobalLogger)
import           System.Timeout             (timeout)


import           Babyconf
import           Babysitter

data Options = Options {
  optMQTTURL         :: URI
  , optMQTTLWTTopic  :: Maybe Text
  , optMQTTLWTMsg    :: Maybe BL.ByteString
  , optPushoverToken :: Text
  , optPushoverUser  :: Text
  , optConfFile      :: String
  , optDelaySeconds  :: Int
  }

options :: Parser Options
options = Options
  <$> option (maybeReader parseURI) (long "mqtt-uri" <> showDefault <> value (fromJust $ parseURI "mqtt://test.mosquitto.org/#babysitter") <> help "mqtt broker URI")
  <*> option mt (long "mqtt-lwt-topic" <> showDefault <> value Nothing <> help "mqtt last will topic")
  <*> option mb (long "mqtt-lwt-msg" <> showDefault <> value Nothing <> help "mqtt last will message")
  <*> strOption (long "pushover-token" <> showDefault <> value "" <> help "pushover token")
  <*> strOption (long "pushover-user" <> showDefault <> value "" <> help "pushover user")
  <*> strOption (long "conf" <> showDefault <> value "baby.conf" <> help "config file")
  <*> option auto (long "delay" <> value 0 <> help "seconds to wait before starting influx watcher")

  where
    mt = maybeReader $ pure.pure.pack
    mb = maybeReader $ pure.pure . BC.pack

timedout :: PushoverConf -> Action -> MQTTClient -> Event -> Text -> IO ()

-- Setting values.
timedout _ (ActSet t m r) mc ev topic = do
  infoM rootLoggerName $ unpack topic <> " - " <> show ev <> " -> set " <> unpack t
  to ev
    where
      to TimedOut = publishq mc t m r QoS2 mempty
      to _        = pure ()

-- Clearing values.
timedout _ ActDelete mc ev topic = do
  infoM rootLoggerName $ unpack topic <> " - " <> show ev <> " -> delete"
  to ev
    where
      to TimedOut = do
        infoM rootLoggerName $ "deleting " <> unpack topic <> " after timeout"
        publishq mc topic "" True QoS2 mempty
      to _        = pure ()

-- Alerting via pushover.
timedout (PushoverConf tok umap) (ActAlert users) _ ev topic = do
  infoM rootLoggerName $ unpack topic <> " - " <> show ev <> " -> " <> show users
  to ev

    where
      to TimedOut =
        mapM_ (\usr -> let m = (message tok usr (topic <> " timed out"))
                               {_title="Babysitter:  Timed Out"} in
                         void $ sendMessage m) users'
      to Returned =
        mapM_ (\usr -> let m = (message tok usr (topic <> " came back"))
                               {_title="Babysitter:  Came Back"} in
                         void $ sendMessage m) users'
      to _ = pure ()

      users' = map (umap Map.!) users

withMQTT :: URI -> Protocol -> Maybe Text -> Maybe BL.ByteString -> (MQTTClient -> Text -> BL.ByteString -> [Property] -> IO ()) -> (MQTTClient -> IO ()) -> IO ()
withMQTT u pl mlwtt mlwtm cb f = bracket connto normalDisconnect go

  where
    mpl MQTT311 = Protocol311
    mpl MQTT5   = Protocol50

    conn = connectURI mqttConfig{_cleanSession=True,
                                 _protocol=mpl pl,
                                 _lwt=mkLWT <$> mlwtt <*> mlwtm <*> Just False,
                                 _msgCB=SimpleCallback cb} u

    connto = timeout 15000000 conn >>= maybe (fail ("timed out connecting to " <> show u)) pure

    go mc = do
      f mc
      r <- waitForClient mc
      infoM rootLoggerName $ mconcat ["Disconnected from ", show u, " ", show r]


runMQTTWatcher :: PushoverConf -> Source -> IO ()
runMQTTWatcher pc (Source (u,pl,mlwtt,mlwtm) watches) = do
  let (instant, timeouts) = partition (\(Watch _ i _) -> i == 0) watches
      toThings = map (\(Watch t i action) -> (t, (i, timedout pc action))) timeouts
      allThings = map (\(Watch t i action) -> (t, (i, timedout pc action))) watches
  wd <- mkWatchDogs (bestMatch toThings)
  feedStartup wd undefined timeouts

  forever $ do
    catch (withMQTT u pl mlwtt mlwtm (gotMsg (wd, instant)) (subAndWait allThings)) (
      \e -> errorM rootLoggerName $ mconcat ["connection to ", show u, ": ",
                                             show (e :: SomeException)])

    threadDelay (seconds 5)

    where
      gotMsg _ _ _ "" _ = pure ()
      gotMsg (wd, instant) c t m _
        | instMatch = alertMsg (TE.decodeUtf8 . BL.toStrict $ m)
        | otherwise = feed wd t c
        where
          insts = filter (\(Watch x _ _) -> x `match` t) instant
          instMatch = (not . null) insts
          alertMsg :: Text -> IO ()
          alertMsg b = do
            infoM rootLoggerName $ mconcat ["Instant alert: ", show users, " ", show t, ", ", show m]
            mapM_ (\usr -> let msg = (message tok usr t){_title="Babysitter Now: " <> t, _body=b} in
                             void $ sendMessage msg) users'
          users = concatMap ufunc insts
          users' = map (umap Map.!) users
          ufunc (Watch _ _ (ActAlert x)) = x
          ufunc _                        = []
          (tok, umap) = let PushoverConf t' m' = pc in (t', m')

      bestMatch [] t = error $ "no good match for " <> unpack t
      bestMatch ((x,r):xs) t
        | x `match` t = r
        | otherwise = bestMatch xs t
      -- Feed all the non-wildcarded watches to the watch dog so
      -- timeouts are meaningful from zero state.
      feedStartup _ _ [] = pure ()
      feedStartup wd mc (Watch t i _:xs)
        | i == 0             = feedStartup wd mc xs
        | "#" `isSuffixOf` t = feedStartup wd mc xs
        | "+/" `isInfixOf` t = feedStartup wd mc xs
        | "/+" `isInfixOf` t = feedStartup wd mc xs
        | otherwise          = feed wd t mc >> feedStartup wd mc xs

      subAndWait things mc = do
        infoM rootLoggerName $ mconcat ["Subscribing at ", show u, " - ", show [(t,subOptions{_subQoS=QoS2}) | (t,_) <- things]]
        subrv <- subscribe mc [(t,subOptions{_subQoS=QoS2}) | (t,_) <- things] mempty
        infoM rootLoggerName $ mconcat ["Sub response from ", show u, ": ", show subrv]

data TSOnly = TSOnly UTCTime (HashMap Text Text) deriving(Show)

instance QueryResults TSOnly where
  parseResults prec = parseResultsWithDecoder strictDecoder $ \_ m columns fields ->
    TSOnly <$> (getField "time" columns fields >>= parseUTCTime prec) <*> pure m

data Status = Clear | Alerting deriving(Eq, Show)

runInfluxWatcher :: PushoverConf -> Source -> IO ()
runInfluxWatcher pc (Source (u,_,_,_) watches) = do
  let (Just uauth) = uriAuthority u
      h = uriRegName uauth
      dbname = drop 1 $ uriPath u
      qp = queryParams (fromString dbname) & server.host .~ fromString h

  periodically mempty (watchAll qp watches)

  where
    periodically st f = do
      st' <- f st
      threadDelay (seconds 60)
      periodically st' f

    watchAll :: QueryParams -> [Watch] -> Map Text Status -> IO (Map Text Status)
    watchAll qp ws m = Map.fromList . Prelude.concat <$> mapM watchOne ws
      where
        watchOne :: Watch -> IO [(Text,Status)]
        watchOne w@(Watch t _ _) = do
          let q = fromString . unpack $ t
          r <- IDB.query qp q :: IO (V.Vector TSOnly)
          now <- getCurrentTime
          mapM (maybeAlert w now) (V.toList r)

        maybeAlert :: Watch -> UTCTime -> TSOnly -> IO (Text, Status)
        maybeAlert (Watch t i act) now (TSOnly x tags) = do
          let age = truncate $ diffUTCTime now x
              firing = seconds age > i
              newst = if firing then Alerting else Clear
              ev = if newst == Alerting then TimedOut else Returned
              msg = if null tags then t else (t <> tagstr tags)
              shouldAlert = firing == (Map.findWithDefault Clear msg m == Clear)
          when shouldAlert $ timedout pc act undefined ev msg
          pure $ (msg, newst)

        tagstr :: HashMap Text Text -> Text
        tagstr t
          | null t = ""
          | otherwise = Data.Text.concat [" [",
                                          (intercalate ", " . map (\(k,v) -> k <> "=" <> v) . HM.toList) t,
                                          "]"]

runWatcher :: Options -> PushoverConf -> Source -> IO ()
runWatcher Options{..} pc src@(Source (u,_,_,_) _)
  | isMQTT = runMQTTWatcher pc src
  | isInflux = threadDelay (seconds optDelaySeconds) >> runInfluxWatcher pc src
  | otherwise = fail ("Don't know how to watch: " <> show u)

  where isMQTT = uriScheme u `elem` ["mqtt:", "mqtts:"]
        isInflux = uriScheme u == "influx:"

run :: Options -> IO ()
run opts@Options{..} = do
  (Babyconf dests srcs) <- parseConfFile optConfFile
  mapConcurrently_ (runWatcher opts dests) srcs

main :: IO ()
main = do
  updateGlobalLogger rootLoggerName (setLevel INFO)
  run =<< execParser opts

  where opts = info (options <**> helper)
          ( fullDesc <> progDesc "Watch the things.")
