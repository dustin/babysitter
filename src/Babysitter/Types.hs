module Babysitter.Types where

import           Data.Text (Text)

type ServiceKey = Text

type AlertFun a b m = b -> Event -> a -> m ()

data Event = Created | Returned | TimedOut deriving (Eq, Show)
