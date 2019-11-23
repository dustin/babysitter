{-# LANGUAGE RecordWildCards #-}

module Babysitter (
  AlertFun, WatchDogs, mkWatchDogs, feed, heel,
  Event(..),
  -- * Convenience functions
  millis, seconds, minutes,
  ) where

import           Control.Concurrent.Async (Async, async, cancel)
import           Control.Concurrent.STM   (TChan, TVar, atomically, modifyTVar',
                                           newTChanIO, newTVarIO, readTChan,
                                           readTVar, readTVarIO, writeTChan,
                                           writeTVar)
import           Control.Monad            (unless)
import           Data.Map.Strict          (Map)
import qualified Data.Map.Strict          as Map
import           Data.Set                 (Set)
import qualified Data.Set                 as Set
import           System.Timeout           (timeout)

type AlertFun a b = b -> Event -> a -> IO ()

type Watchers a b = Map a (Async (), TChan (), AlertFun a b)

type State a b = TVar (Watchers a b)

data WatchDogs a b = WatchDogs {
  _cfgFor :: a -> (Int, AlertFun a b)
  , _st   :: State a b
  , _seen :: TVar (Set a)
  }

data Event = Created | Returned | TimedOut deriving (Eq, Show)

mkWatchDogs :: Ord a => (a -> (Int, AlertFun a b)) -> IO (WatchDogs a b)
mkWatchDogs _cfgFor = do
  _st <- newTVarIO mempty
  _seen <- newTVarIO mempty
  pure WatchDogs{..}

heel :: Ord a => WatchDogs a b -> IO ()
heel WatchDogs{..} = do
  m <- atomically $ do
    m <- readTVar _st
    writeTVar _st mempty
    writeTVar _seen mempty
    pure m
  mapM_ (\(a,_,_) -> cancel a) $ Map.elems m

feed :: Ord a => WatchDogs a b -> a -> b -> IO ()
feed WatchDogs{..} t a = do
  m <- readTVarIO _st
  case Map.lookup t m of
    Nothing       -> startWatcher
    Just (_,ch,_) -> atomically $ writeTChan ch ()

  where
    startWatcher :: IO ()
    startWatcher = do
      let (i, f) = _cfgFor t
      nevent >>= \ev -> f a ev t
      ch <- newTChanIO
      ws <- async $ watch ch i f
      added <- atomically $ do
        m <- readTVar _st
        mightStart (ws,ch,f) $ Map.lookup t m

      unless added $ cancel ws

          where
            mightStart _ (Just _) = pure False
            mightStart x Nothing = do
              modifyTVar' _st (Map.insert t x)
              modifyTVar' _seen (Set.insert t)
              pure True

    nevent = readTVarIO _seen >>= \s -> if Set.member t s then pure Returned else pure Created

    watch ch i f = do
        r <- timeout i w
        case r of
          Nothing -> f a TimedOut t >> unmap
          Just _  -> watch ch i f

          where w = atomically . readTChan $ ch
                unmap = atomically $ modifyTVar' _st (Map.delete t)

millis :: Int -> Int
millis = (* 1000)

seconds :: Int -> Int
seconds = millis . (* 1000)

minutes :: Int -> Int
minutes = seconds . (* 60)
