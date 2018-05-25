module Test.Main where

import Prelude

import Control.Alt ((<|>))
import Control.Monad.Aff (Aff, delay, launchAff_)
import Control.Monad.Aff as Aff
import Control.Monad.Aff.AVar as AVar
import Control.Monad.Aff.Bus as Bus
import Control.Monad.Aff.Class (class MonadAff, liftAff)
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.Eff.Console (log)
import Control.Monad.IO (IO, runIO')
import Control.Monad.Saga (SagaT, TakeLatestResult(..))
import Control.Monad.Saga (put, run, select, takeEvery, takeLatest) as Saga
import Control.Monad.Saga.Reducer (rootReducer) as Saga
import Control.Monad.Saga.Runnable (class Runnable)
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
reduce _ s = s

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

  let rootReducer = Saga.rootReducer stateBus reduce :: SagaT State Action (Aff _) Unit
  runIO' $ Saga.run actionBus stateBus [rootReducer, tick, tock, guarded, latestTick, latestTock]
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

guarded :: ∀ m. MonadAff _ m => Runnable m => SagaT State Action m Unit
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

latestTick :: ∀ s m. MonadAff _ m => SagaT s Action m Unit
latestTick = do
  res <- Saga.takeLatest case _ of
    ActionTick _ -> Just unit
    _ -> Nothing
    
  case res of
    Superseded -> liftEff $ log "Superseded tick"
    Latest _ -> do
      liftAff $ Aff.delay (Milliseconds 10000.0) -- will be always superseded
      liftEff $ log "latest tick"

latestTock :: ∀ s m. MonadAff _ m => SagaT s Action m Unit
latestTock = do
  res <- Saga.takeLatest case _ of
    ActionTick _ -> Just unit
    _ -> Nothing
    
  case res of
    Superseded -> liftEff $ log "Superseded tock"
    Latest _ -> do
      liftAff $ Aff.delay (Milliseconds 100.0)      
      liftEff $ log "latest tock"

