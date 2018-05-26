module Control.Monad.Saga.ForkPool  (
    ForkPool,
    add,
    kill,
    make
) where

import Prelude

import Effect.Aff (Aff, Fiber)
import Effect.Aff as Aff
import Effect.Aff.AVar (AVar)
import Effect.Aff.AVar as AVar
import Effect.Aff.Class (class MonadAff, liftAff)

newtype ForkPool = ForkPool {
    max :: AVar Int
}

make :: Int -> Aff ForkPool
make n = do
    max <- AVar.new n
    pure $ ForkPool {max}

add :: ∀ a m. MonadAff m => ForkPool -> Aff a -> m (Fiber a)
add (ForkPool {max}) task = liftAff do 
    m <- AVar.take max
    let newConc = m - 1
    let shouldBlock = newConc <= 0
    if shouldBlock
        then pure unit
        else AVar.put newConc max
    let fin = do
            c <- if shouldBlock then pure 0 else AVar.take max
            AVar.put (c + 1) max

    Aff.forkAff $ Aff.finally fin $ task

kill :: ForkPool -> Aff Unit
kill (ForkPool {max}) = AVar.kill (Aff.error "[forkpool] killed") max