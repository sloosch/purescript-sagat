module Control.Monad.Saga.Runnable where

import Prelude

import Control.Monad.Aff (Aff)
import Control.Monad.Aff.Class (liftAff)
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.IO (IO)

class Functor m <= Runnable m where
  runAsIO :: m ~> IO

instance runnableIO :: Runnable IO where
    runAsIO = id

instance runnableAff :: Runnable (Aff e) where
    runAsIO = liftAff

instance runnableEff :: Runnable (Eff e) where
    runAsIO = liftEff
