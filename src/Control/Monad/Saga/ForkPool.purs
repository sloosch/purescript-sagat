module Control.Monad.Saga.ForkPool  (
    bounded,
    ForkPool,
    add,
    block,
    shutdown,
    class NatIso,
    forwards,
    backwards
) where

import Prelude

import Control.Monad.Aff (Aff, Fiber)
import Control.Monad.Aff as Aff
import Control.Monad.Aff.AVar (AVar)
import Control.Monad.Aff.AVar as AVar
import Control.Monad.Aff.Class (class MonadAff, liftAff)
import Control.Monad.Aff.Unsafe (unsafeCoerceAff)
import Control.Monad.IO (IO, runIO')
import Unsafe.Coerce (unsafeCoerce)


class NatIso m n | n -> m where
    forwards :: m ~> n
    backwards :: n ~> m

instance natIsoAffAff :: NatIso (Aff e) (Aff e) where
    forwards = id
    backwards = id

instance natIsoAffIO :: NatIso (Aff e) (IO) where
    forwards = liftAff
    backwards = unsafeCoerceAff <<< runIO'

newtype ForkPool n = ForkPool {
    add :: ∀ r e. n r -> n (Fiber e r),
    shutdown :: ∀ e. Aff e Unit
}

bounded :: ∀ m n. MonadAff _ m => Monad n => NatIso (Aff _) n => Int -> m (ForkPool n)
bounded n = liftAff do
    maxVar <- AVar.makeVar n
    taskVar <- AVar.makeEmptyVar
    let
        loopFork = do
            task <- AVar.takeVar taskVar
            conc <- AVar.takeVar maxVar
            let newConc = conc - 1
            let shouldBlock = newConc <= 0
            if shouldBlock
                then pure unit
                else AVar.putVar newConc maxVar
            let fin = do
                    c <- if shouldBlock then pure 0 else AVar.takeVar maxVar
                    AVar.putVar (c + 1) maxVar

            _ <- Aff.forkAff $ Aff.finally fin $ Aff.apathize $ Aff.joinFiber task

            loopFork
    loopFiber <- Aff.forkAff loopFork
    
    let shutdownImpl = Aff.killFiber (Aff.error "[saga] fork pool shutdown") loopFiber

    pure $ ForkPool {add: map unsafeCoerce <<< addImpl taskVar, shutdown: unsafeCoerceAff shutdownImpl}

    where
    addImpl :: ∀ r. AVar (Fiber _ Unit) -> n r -> n (Fiber _ r)
    addImpl taskVar task = do
        suspended <- forwards $ Aff.suspendAff $ backwards task
        forwards $ AVar.putVar (void suspended) taskVar
        pure suspended

add :: ∀ n e r. ForkPool n -> n r -> n (Fiber e r)
add (ForkPool f) = f.add

block :: ∀ n r. Applicative n => ForkPool n -> n r -> n r
block (ForkPool f) n = f.add n *> n

shutdown :: ∀ e n m. MonadAff e m => ForkPool n -> m Unit
shutdown (ForkPool f) = liftAff f.shutdown