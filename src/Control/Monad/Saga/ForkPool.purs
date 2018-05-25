module Control.Monad.Saga.ForkPool  (
    ForkPool,
    add,
    kill,
    make
) where

import Prelude

import Control.Monad.Aff (Aff, Fiber)
import Control.Monad.Aff as Aff
import Control.Monad.Aff.AVar (AVar)
import Control.Monad.Aff.AVar as AVar
import Control.Monad.Aff.Class (class MonadAff, liftAff)
import Control.Monad.IO (runIO')
import Control.Monad.Saga.Runnable (class Runnable, runAsIO)

newtype ForkPool = ForkPool {
    max :: AVar Int
}

make :: Int -> Aff _ ForkPool
make n = do
    max <- AVar.makeVar n
    pure $ ForkPool {max}

add :: ∀ a m t. Runnable t => MonadAff _ m => ForkPool -> t a -> m (Fiber _ a)
add (ForkPool {max}) task =liftAff do 
    m <- AVar.takeVar max
    let newConc = m - 1
    let shouldBlock = newConc <= 0
    if shouldBlock
        then pure unit
        else AVar.putVar newConc max
    let fin = do
            c <- if shouldBlock then pure 0 else AVar.takeVar max
            AVar.putVar (c + 1) max

    Aff.forkAff $ Aff.finally fin $ runIO' $ runAsIO task

kill :: ForkPool -> Aff _ Unit
kill (ForkPool {max}) = AVar.killVar (Aff.error "[forkpool] killed") max