module Main where

import Prelude

import Control.Alt ((<|>))
import Control.Monad.Aff (delay, launchAff_)
import Control.Monad.Aff.AVar as AVar
import Control.Monad.Aff.Bus as Bus
import Control.Monad.Aff.Class (class MonadAff, liftAff)
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.Eff.Console (log)
import Control.Monad.IO (IO, runIO')
import Control.Monad.Saga (SagaT)
import Control.Monad.Saga (put, run, select, takeEvery) as Saga
import Control.Monad.Saga.Reducer (rootReducer) as Saga
import Control.MonadZero (guard)
import Data.Maybe (Maybe(..))
import Data.Time.Duration (Milliseconds(..))

data Action = ActionTick Number | ActionTock Number

type State = {
  tickCount :: Int,
  tockCount :: Int
}

initState :: State
initState = {
  tickCount: 0,
  tockCount: 0
}

reduce :: Action -> State -> State
reduce (ActionTick _) prev = prev{tickCount = prev.tickCount + 1}
reduce (ActionTock _) prev = prev{tockCount = prev.tockCount + 1}

tick :: ∀ m. MonadAff _ m => SagaT State Action m Unit
tick = do
  waitTime <- Saga.takeEvery case _ of
        ActionTock wait -> Just wait
        _ -> Nothing
  
  liftAff $ delay (Milliseconds waitTime)
  Saga.put (ActionTick 500.0)
  
  tickCount <- Saga.select _.tickCount
  liftEff $ log $ "tick " <> show tickCount
    

tock :: ∀ m. MonadAff _ m => SagaT State Action m Unit
tock = do
  waitTime <- Saga.takeEvery case _ of
      ActionTick wait -> Just wait
      _ -> Nothing
  
  liftAff $ delay (Milliseconds waitTime)
  Saga.put (ActionTock 1000.0)
  
  tockCount <- Saga.select _.tockCount
  liftEff $ log $ "tock " <> show tockCount

main :: forall e. Eff _ Unit
main = launchAff_ do
  actionBus <- Bus.make
  stateBus <- Bus.make

  runIO' $ Saga.run actionBus stateBus [raceRunner]

  let rootReducer = Saga.rootReducer stateBus reduce
  runIO' $ Saga.run actionBus stateBus [rootReducer, tick, tock, guarded]
  Bus.write initState stateBus
  Bus.write (ActionTick 500.0) actionBus

raceRunner :: ∀ s a. SagaT s a IO Unit
raceRunner = do
  res <- raceA <|> raceB
  liftEff $ log $ "race winner " <> res

  where
  raceA ::SagaT s a IO String
  raceA = do
      liftAff $ delay (Milliseconds 1000.0)
      pure "A"

  raceB :: SagaT s a IO String
  raceB = do
      liftAff $ delay (Milliseconds 500.0)
      pure "B"

guarded :: SagaT State Action IO Unit
guarded = do
    cntVar <- liftAff $ AVar.makeVar 0
    wait <- Saga.takeEvery case _ of
        ActionTick w -> Just w
        _ -> Nothing
    cnt <- liftAff do
      c <- AVar.takeVar cntVar
      AVar.putVar (c + 1) cntVar
      pure (c + 1)
    
    guard (cnt > 2)

    inState <- Saga.select _.tickCount

    liftEff $ log $ "Guard finished " <> show inState