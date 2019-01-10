{-# LANGUAGE OverloadedStrings #-}

import           Control.Concurrent     (threadDelay)
import           Control.Concurrent.STM (TChan, TVar, atomically, modifyTVar',
                                         newTChan, newTChanIO, newTVarIO,
                                         readTChan, readTVar, readTVarIO, retry,
                                         writeTChan, writeTVar)
import           Control.Monad          (foldM_)
import           Data.Void              (Void)

import           Test.QuickCheck
import           Test.Tasty
import           Test.Tasty.HUnit
import           Test.Tasty.QuickCheck  as QC

import           Babysitter

testTopicMatching :: [TestTree]
testTopicMatching =
  let cfgs = [("a/#", 1), ("a/b", 2), ("a/b/c", 3), ("r/#", 9)] in
    map (\(p,want) -> testCase (show p) $ assertEqual "" want (topicMatch 3600 cfgs p)) [
    ("a/c", 1), ("a/b", 2), ("a/d", 1), ("a/b/c", 3), ("r/o/f/l", 9), ("d", 3600)]

testWatchDoggin :: Assertion
testWatchDoggin = do
  x <- newTVarIO []
  let keys = "abcdefg" :: String
  wd <- mkWatchDogs (const (millis 100, tod x))
  foldM_ (\_ k -> feed wd k ()) undefined keys
  foldM_ (\_ k -> feed wd k () >> threadDelay (millis 5)) undefined keys
  l <- atomically $ do
    l <- readTVar x
    if length l < length keys then retry else pure l
  assertEqual "" keys (reverse l)

  where
    tod :: TVar [Char] -> AlertFun Char ()
    tod x _ TimedOut t = (atomically $ modifyTVar' x (t:))
    tod _ _ e t        = pure ()

testHeelin :: Assertion
testHeelin = do
  x <- newTVarIO 0
  let keys = "abcdefg" :: String
  wd <- mkWatchDogs (const (millis 5, tod x))
  foldM_ (\_ k -> feed wd k ()) undefined keys
  heel wd
  threadDelay (millis 50) -- enough time for something to surey have fired
  r <- readTVarIO x
  assertEqual "" 0 r

  where
    tod :: TVar Int -> AlertFun Char ()
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
    tod :: TVar Int -> TVar Int -> AlertFun Char ()
    tod tv _ _ TimedOut t = (atomically $ modifyTVar' tv succ)
    tod _ rv _ Returned t = (atomically $ modifyTVar' rv succ)
    tod _ _ _ e t         = pure ()


tests :: [TestTree]
tests = [
  testGroup "topic matching" testTopicMatching,

  testCase "watchdog firing" testWatchDoggin,
  testCase "watchdog heeling" testHeelin,
  testCase "return of the watchdog" testReturn
  ]

main :: IO ()
main = defaultMain $ testGroup "All Tests" tests
