{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Babysitter (
  AlertFun, WatchDogs, mkWatchDogs, feed, heel,
  Event(..),
  -- * Convenience functions
  millis, seconds, minutes, topicMatch
  ) where

import           Control.Concurrent.Async (Async, async, cancel)
import           Control.Concurrent.STM   (TChan, TVar, atomically, modifyTVar',
                                           newTChanIO, newTVarIO, readTChan,
                                           readTVar, readTVarIO, writeTChan,
                                           writeTVar)
import           Data.Map.Strict          (Map)
import qualified Data.Map.Strict          as Map
import           Data.Set                 (Set)
import qualified Data.Set                 as Set
import           Data.Text                (Text, dropEnd, dropWhileEnd)
import           System.Timeout           (timeout)

type AlertFun a = Event -> a -> IO ()

type Watchers a = Map a (Async (), TChan (), AlertFun a)

type State a = TVar (Watchers a)

data (Ord a, Eq a) => WatchDogs a = WatchDogs {
  _cfgFor :: a -> (Int, AlertFun a)
  , _st   :: State a
  , _seen :: TVar (Set a)
  }

data Event = Created | Returned | TimedOut deriving (Eq, Show)

mkWatchDogs :: (Ord a, Eq a) => (a -> (Int, AlertFun a)) -> IO (WatchDogs a)
mkWatchDogs _cfgFor = do
  _st <- newTVarIO mempty
  _seen <- newTVarIO mempty
  pure WatchDogs{..}

heel :: Ord a => WatchDogs a -> IO ()
heel WatchDogs{..} = do
  m <- atomically $ do
    m <- readTVar _st
    writeTVar _st mempty
    writeTVar _seen mempty
    pure m
  mapM_ (\(a,_,_) -> cancel a) $ Map.elems m

feed :: (Ord a, Eq a) => WatchDogs a -> a -> IO ()
feed WatchDogs{..} t = do
  m <- readTVarIO _st
  case Map.lookup t m of
    Nothing       -> startWatcher
    Just (_,ch,_) -> atomically $ writeTChan ch ()

  where
    startWatcher :: IO ()
    startWatcher = do
      let (i, f) = _cfgFor t
      nevent >>= \ev -> f ev t
      ch <- newTChanIO
      a <- async $ watch ch i f
      atomically $ do
        modifyTVar' _st (Map.insert t (a,ch,f))
        modifyTVar' _seen (Set.insert t)

    nevent = readTVarIO _seen >>= \s -> if Set.member t s then pure Returned else pure Created

    watch ch i f = do
        r <- timeout i w
        case r of
          Nothing -> f TimedOut t >> unmap
          Just _  -> watch ch i f

          where w = atomically . readTChan $ ch
                unmap = atomically $ modifyTVar' _st (Map.delete t)

millis :: Int -> Int
millis = (* 1000)

seconds :: Int -> Int
seconds = millis . (* 1000)

minutes :: Int -> Int
minutes = seconds . (* 60)

-- | Topic match matches MQTT topics since that's convenient for me.
topicMatch :: a -> [(Text,a)] -> Text -> a
topicMatch def = lu . Map.fromList

  where
    lu m p = case Map.lookup p m of
               Just x  -> x
               Nothing -> shrink (chop p)
      where
        chop = dropEnd 1 . dropWhileEnd (/= '/')

        shrink "" = def
        shrink t = case Map.lookup (t <> "/#") m of
                     Just x  -> x
                     Nothing -> shrink (chop t)

