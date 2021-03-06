{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TupleSections     #-}

module Main where

import           Control.Concurrent      (threadDelay)
import           Control.Exception       (SomeException)
import           Control.Lens            ((&), (.~))
import           Control.Monad           (forever, void, when)
import           Control.Monad.Catch     (bracket, catch)
import           Control.Monad.IO.Class  (MonadIO (..))
import           Control.Monad.IO.Unlift (withRunInIO)
import           Control.Monad.Logger    (LoggingT, ToLogStr (..),
                                          runStderrLoggingT, toLogStr)
import           Control.Monad.Reader    (MonadReader, ReaderT (..), asks, runReaderT)
import qualified Data.ByteString.Lazy    as BL
import           Data.HashMap.Strict     (HashMap)
import qualified Data.HashMap.Strict     as HM
import           Data.List               (partition)
import           Data.Map.Strict         (Map)
import qualified Data.Map.Strict         as Map
import           Data.Maybe              (fromJust, fromMaybe)
import           Data.String             (fromString)
import           Data.Text               (Text, concat, intercalate, isInfixOf, isSuffixOf, unpack)
import           Data.Time
import qualified Data.Vector             as V
import           Database.InfluxDB       as IDB
import           Network.MQTT.Client
import           Network.MQTT.Topic      (Filter, match, mkTopic, unFilter, unTopic)
import           Network.URI
import           Options.Applicative     (Parser, auto, execParser, fullDesc, help, helper, info, long, maybeReader,
                                          option, progDesc, showDefault, strOption, value, (<**>))
import           UnliftIO.Async          (mapConcurrently_)
import           UnliftIO.Timeout        (timeout)


import           Babyconf
import           Babysitter
import           Babysitter.Notification
import           Babysitter.Types
import           Babysitter.Logging

data Options = Options {
  optMQTTURL         :: URI
  , optPushoverToken :: Text
  , optPushoverUser  :: Text
  , optConfFile      :: FilePath
  , optDelaySeconds  :: Int
  }

options :: Parser Options
options = Options
  <$> option (maybeReader parseURI) (long "mqtt-uri" <> showDefault <> value (fromJust $ parseURI "mqtt://test.mosquitto.org/#babysitter") <> help "mqtt broker URI")
  <*> strOption (long "pushover-token" <> showDefault <> value "" <> help "pushover token")
  <*> strOption (long "pushover-user" <> showDefault <> value "" <> help "pushover user")
  <*> strOption (long "conf" <> showDefault <> value "baby.conf" <> help "config file")
  <*> option auto (long "delay" <> value 0 <> help "seconds to wait before starting influx watcher")

data Env = Env {
  destinations :: Destinations
  , cliOpts    :: Options
  }

type Babysitter = ReaderT Env (LoggingT IO)

askDestinations :: MonadReader Env m => m Destinations
askDestinations = asks destinations

askOpts :: MonadReader Env m => m Options
askOpts = asks cliOpts

instance ToLogStr Topic where
  toLogStr = toLogStr . unTopic

timedout :: Destinations -> Action -> MQTTClient -> Event -> Text -> Babysitter ()

-- Setting values.
timedout _ (ActSet t m r) mc ev topic = do
  logInfo $ toLogStr topic <> " - " <> (toLogStr . show) ev <> " -> set " <> toLogStr t
  to ev
    where
      to TimedOut = liftIO $ publishq mc t m r QoS2 mempty
      to _        = pure ()

-- Clearing values.
timedout _ ActDelete mc ev topic = do
  logInfo $ unpack topic <> " - " <> show ev <> " -> delete"
  to ev
    where
      to TimedOut = case mkTopic topic of
                      Nothing -> pure ()
                      Just t -> do
                        logInfo $ "deleting " <> unpack topic <> " after timeout"
                        liftIO $ publishq mc t "" True QoS2 mempty
      to _        = pure ()

-- Alerting via pushover.
timedout umap (ActAlert users) _ ev topic = do
  logInfo $ unpack topic <> " - " <> show ev <> " -> " <> show users
  when (ev /= Created) $ mapM_ (\d -> notify ev d topic) users'

    where
      users' = map (umap Map.!) users

withMQTT :: URI -> Protocol -> Maybe Topic -> Maybe BL.ByteString -> (MQTTClient -> Topic -> BL.ByteString -> [Property] -> IO ()) -> (MQTTClient -> IO ()) -> Babysitter ()
withMQTT u pl mlwtt mlwtm cb f = withRunInIO $ \unl -> bracket connto normalDisconnect (go unl)

  where
    mpl MQTT311 = Protocol311
    mpl MQTT5   = Protocol50

    conn = connectURI mqttConfig{_cleanSession=True,
                                 _protocol=mpl pl,
                                 _lwt=mkLWT <$> mlwtt <*> mlwtm <*> Just False,
                                 _msgCB=SimpleCallback cb} u

    connto = timeout 15000000 conn >>= maybe (fail ("timed out connecting to " <> show u)) pure

    go unl mc = do
      f mc
      r <- waitForClient mc
      void . unl . logInfo $ mconcat ["Disconnected from ", show u, " ", show r]

delay :: MonadIO m => Int -> m ()
delay = liftIO . threadDelay

alertNow :: [Watch a] -> Text -> Babysitter ()
alertNow insts t = do
  logInfo $ mconcat ["Instant alert: ", show users, " ", show t]
  dests <- findUsers <$> askDestinations
  mapM_ (\d -> notify TimedOut d t) dests
    where
      users = concatMap ufunc insts
      ufunc (Watch _ _ (ActAlert x)) = x
      ufunc _                        = []
      findUsers umap = map (umap Map.!) users

runMQTTWatcher :: (URI, Protocol, Maybe Topic, Maybe BL.ByteString) -> [Watch Filter] -> Babysitter ()
runMQTTWatcher (u,pl,mlwtt,mlwtm) watches = do
  ds <- askDestinations
  let (instant, timeouts) = partition (\(Watch _ i _) -> i == 0) watches
      toThings = map (\(Watch t i action) -> (t, (i, timedout ds action))) timeouts
      allThings = map (\(Watch t i action) -> (t, (i, timedout ds action))) watches
  wd <- liftIO $ mkWatchDogs (bestMatch toThings)
  feedStartup wd undefined timeouts

  forever $ do
    withRunInIO $ \unl ->
                    catch (unl $ withMQTT u pl mlwtt mlwtm (gotMsg unl (wd, instant)) (subAndWait unl allThings)) (
      \e -> void . unl . logErr $ mconcat ["connection to ", show u, ": ",
                                           show (e :: SomeException)])

    delay (seconds 5)

    where
      gotMsg _ _ _ _ "" _ = pure ()
      gotMsg unl (wd, instant) c t _ _
        | instMatch = unl $ alertNow insts (unTopic t)
        | otherwise = unl $ feed wd (unTopic t) c
        where
          insts = filter (\(Watch x _ _) -> x `match` t) instant
          instMatch = (not . null) insts

      bestMatch [] t = error $ "no good match for " <> show t
      bestMatch ((x,r):xs) t
        | x `match` (fromString . unpack) t = r
        | otherwise = bestMatch xs t
      -- Feed all the non-wildcarded watches to the watch dog so
      -- timeouts are meaningful from zero state.
      feedStartup _ _ [] = pure ()
      feedStartup wd mc (Watch t i _:xs)
        | i == 0              = feedStartup wd mc xs
        | "#" `isSuffixOf` t' = feedStartup wd mc xs
        | "+/" `isInfixOf` t' = feedStartup wd mc xs
        | "/+" `isInfixOf` t' = feedStartup wd mc xs
        | otherwise           = feed wd t' mc >> feedStartup wd mc xs
        where t' = unFilter t

      subAndWait unl things mc = unl $ do
        logInfo $ mconcat ["Subscribing at ", show u, " - ", show [(t,subOptions{_subQoS=QoS2}) | (t,_) <- things]]
        subrv <- liftIO $  subscribe mc [(t,subOptions{_subQoS=QoS2}) | (t,_) <- things] mempty
        logInfo $ mconcat ["Sub response from ", show u, ": ", show subrv]

data TSOnly = TSOnly UTCTime (HashMap Text Text) deriving(Show)

instance QueryResults TSOnly where
  parseMeasurement prec _name tags columns fields =
    TSOnly <$> (getField "time" columns fields >>= parseUTCTime prec) <*> pure tags

data Status = Clear | Alerting deriving(Eq, Show)

runInfluxWatcher :: URI -> [Watch Text] -> Babysitter ()
runInfluxWatcher u watches = do
  let uauth = fromMaybe (error "bad url auth") $ uriAuthority u
      h = uriRegName uauth
      dbname = drop 1 $ uriPath u
      qp = queryParams (fromString dbname) & server.host .~ fromString h

  periodically mempty (watchAll qp watches)

  where
    periodically st f = do
      st' <- f st
      delay (seconds 60)
      periodically st' f

    watchAll :: QueryParams -> [Watch Text] -> Map Text Status -> Babysitter (Map Text Status)
    watchAll qp ws m = Map.fromList . Prelude.concat <$> traverse watchOne ws
      where
        watchOne :: Watch Text -> Babysitter [(Text,Status)]
        watchOne w@(Watch t _ _) = do
          let q = fromString . unpack $ t
          r <- liftIO (IDB.query qp q :: IO (V.Vector TSOnly))
          now <- liftIO getCurrentTime
          traverse (maybeAlert w now) (V.toList r)

        maybeAlert :: Watch Text -> UTCTime -> TSOnly -> Babysitter (Text, Status)
        maybeAlert (Watch t i act) now (TSOnly x tags) = do
          let age = truncate $ diffUTCTime now x
              firing = seconds age > i
              newst = if firing then Alerting else Clear
              ev = if newst == Alerting then TimedOut else Returned
              msg = if null tags then t else (t <> tagstr tags)
              shouldAlert = firing == (Map.findWithDefault Clear msg m == Clear)
          ds <- askDestinations
          when shouldAlert $ timedout ds act undefined ev msg
          pure $ (msg, newst)

        tagstr :: HashMap Text Text -> Text
        tagstr t
          | null t = ""
          | otherwise = Data.Text.concat [" [",
                                          (intercalate ", " . map (\(k,v) -> k <> "=" <> v) . HM.toList) t,
                                          "]"]

runWatcher :: Source -> Babysitter ()
runWatcher (MQTTSource x ws)   = runMQTTWatcher x ws
runWatcher (InfluxSource u ws) = (optDelaySeconds <$> askOpts) >>= delay >> runInfluxWatcher u ws

runTrans :: Destinations -> Options -> ReaderT Env m a -> m a
runTrans ds opts f = runReaderT f (Env ds opts)

run :: Options -> IO ()
run opts@Options{..} = do
  (Babyconf dests srcs) <- parseConfFile optConfFile
  runStderrLoggingT $ mapConcurrently_ (runTrans dests opts . runWatcher) srcs

main :: IO ()
main = run =<< execParser opts

  where opts = info (options <**> helper)
          ( fullDesc <> progDesc "Watch the things.")
