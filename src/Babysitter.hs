{-# LANGUAGE RecordWildCards #-}

module Babysitter (
  WatchDogs, mkWatchDogs, feed, heel,
  -- * Convenience functions
  millis, seconds, minutes,
  ) where

import           Control.Concurrent.Async (Async, async, cancel)
import           Control.Concurrent.STM   (TChan, TVar, atomically, modifyTVar', newTChanIO, newTVarIO, readTChan,
                                           readTVar, readTVarIO, writeTChan, writeTVar)
import           Control.Monad            (unless, void)
import           Control.Monad.IO.Class   (MonadIO (..))
import           Control.Monad.IO.Unlift  (MonadUnliftIO, withRunInIO)
import           Data.Map.Strict          (Map)
import qualified Data.Map.Strict          as Map
import           Data.Set                 (Set)
import qualified Data.Set                 as Set
import           System.Timeout           (timeout)

import           Babysitter.Types

type Watchers a b m = Map a (Async (), TChan (), AlertFun a b m)

type State a b m = TVar (Watchers a b m)

data WatchDogs a b m = WatchDogs {
  _cfgFor :: a -> (Int, AlertFun a b m)
  , _st   :: State a b m
  , _seen :: TVar (Set a)
  }

mkWatchDogs :: Ord a => (a -> (Int, AlertFun a b m)) -> IO (WatchDogs a b m)
mkWatchDogs _cfgFor = WatchDogs _cfgFor <$> newTVarIO mempty <*> newTVarIO mempty

heel :: (MonadIO m, Ord a) => WatchDogs a b m -> m ()
heel WatchDogs{..} = do
  m <- liftIO . atomically $ do
    m <- readTVar _st
    writeTVar _st mempty
    writeTVar _seen mempty
    pure m
  mapM_ (\(a,_,_) -> liftIO $ cancel a) $ Map.elems m

feed :: (MonadUnliftIO m, Ord a) => WatchDogs a b m -> a -> b -> m ()
feed WatchDogs{..} t a = do
  m <- liftIO $ readTVarIO _st
  case Map.lookup t m of
    Nothing       -> withRunInIO startWatcher
    Just (_,ch,_) -> liftIO . atomically $ writeTChan ch ()

  where
    startWatcher unl = do
      let (i, f) = _cfgFor t
      nevent >>= \ev -> void . unl $ f a ev t
      ch <- newTChanIO
      ws <- async $ watch ch i f unl
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

    watch ch i f unl = do
        r <- timeout i w
        case r of
          Nothing -> (unl $ f a TimedOut t) >> unmap
          Just _  -> watch ch i f unl

          where w = liftIO . atomically . readTChan $ ch
                unmap = atomically $ modifyTVar' _st (Map.delete t)

millis :: Int -> Int
millis = (* 1000)

seconds :: Int -> Int
seconds = millis . (* 1000)

minutes :: Int -> Int
minutes = seconds . (* 60)
