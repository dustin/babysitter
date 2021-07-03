{-# LANGUAGE OverloadedStrings #-}

import           Control.Concurrent     (threadDelay)
import           Control.Concurrent.STM (TChan, TVar, atomically, modifyTVar', newTChan, newTChanIO, newTVarIO,
                                         readTChan, readTVar, readTVarIO, retry, writeTChan, writeTVar)
import           Control.Monad          (foldM_)
import qualified Data.Map.Strict        as Map
import           Data.Void              (Void)
import           Network.URI

import           Test.QuickCheck
import           Test.Tasty
import           Test.Tasty.HUnit
import           Test.Tasty.QuickCheck  as QC

import           Babyconf
import           Babysitter

testWatchDoggin :: Assertion
testWatchDoggin = do
  x <- newTVarIO []
  let keys = "abcdefg" :: String
  wd <- mkWatchDogs (const (millis 500, tod x))
  foldM_ (\_ k -> feed wd k ()) undefined keys
  foldM_ (\_ k -> feed wd k () >> threadDelay (millis 25)) undefined keys
  l <- atomically $ do
    l <- readTVar x
    if length l < length keys then retry else pure l
  assertEqual "" keys (reverse l)

  where
    tod :: TVar [Char] -> AlertFun Char () IO
    tod x _ TimedOut t = (atomically $ modifyTVar' x (t:))
    tod _ _ e t        = pure ()

testHeelin :: Assertion
testHeelin = do
  x <- newTVarIO 0
  let keys = "abcdefg" :: String
  wd <- mkWatchDogs (const (millis 5, tod x))
  foldM_ (\_ k -> feed wd k ()) undefined keys
  heel wd
  threadDelay (millis 100) -- enough time for something to surey have fired
  r <- readTVarIO x
  assertEqual "" 0 r

  where
    tod :: TVar Int -> AlertFun Char () IO
    tod x _ TimedOut t = (atomically $ modifyTVar' x succ)
    tod _ _ e t        = pure ()

testReturn :: Assertion
testReturn = do
  rv <- newTVarIO 0
  tv <- newTVarIO 0
  let keys = "abcdefg" :: String
  wd <- mkWatchDogs (const (millis 5, tod tv rv))
  foldM_ (\_ k -> feed wd k ()) undefined keys
  -- Wait for some timeouts
  atomically $ readTVar tv >>= \r -> if r == 0 then retry else pure ()
  -- Bring stuff back
  foldM_ (\_ k -> feed wd k ()) undefined keys
  -- Wait for something to come back.
  atomically $ readTVar rv >>= \r -> if r == 0 then retry else pure ()
  pure ()

  where
    tod :: TVar Int -> TVar Int -> AlertFun Char () IO
    tod tv _ _ TimedOut t = (atomically $ modifyTVar' tv succ)
    tod _ rv _ Returned t = (atomically $ modifyTVar' rv succ)
    tod _ _ _ e t         = pure ()

testConfig :: Assertion
testConfig = do
  let Just u = parseURI "mqtt://test.mosquitto.org/#babysittertest"
      Just u2 = parseURI "mqtt://test.mosquitto.org/#babysitter2"
      Just iu = parseURI "influx://host:8086/dbname"
  c <- parseConfFile "test/test.conf"
  assertEqual "test.conf" (Babyconf (PushoverConf "pushoverapikey"
                                     (Map.fromList [("dustin","mypushoverkey")]))
                            [MQTTSource (u, MQTT5, Just "errors",
                                     Just "babysitter \226\152\160")
                              [Watch "tmp/#" 300000000 ActDelete,
                               Watch "x/+/y" 1800000000 (ActAlert ["dustin"])],
                             MQTTSource (u2, MQTT311, Nothing, Nothing)
                              [Watch "tmp/#" 60000000 ActDelete],
                             InfluxSource iu
                              [Watch "select last(thing) from stuff" 3600000000 (ActAlert ["dustin"])]
                              ]) c

tests :: [TestTree]
tests = [
  tmout $ testCase "watchdog firing" testWatchDoggin,
  tmout $ testCase "watchdog heeling" testHeelin,
  tmout $ testCase "return of the watchdog" testReturn,
  testCase "test.conf" testConfig
  ]

  where tmout = localOption (Timeout 5000000 "5s")

main :: IO ()
main = defaultMain $ testGroup "All Tests" tests
