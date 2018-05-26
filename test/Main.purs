module Test.Main where

import Prelude

import Control.Alt ((<|>))
import Effect.Aff (Aff, delay, launchAff_)
import Effect.Aff as Aff
import Effect.Aff.AVar as AVar
import Control.Monad.Aff.Bus as Bus
import Effect.Aff.Class (class MonadAff, liftAff)
import Effect (Effect)
import Effect.Class (liftEffect)
import Effect.Console (log)
import Control.Monad.Saga (SagaT, TakeLatestResult(..))
import Control.Monad.Saga (put, run, select, takeEvery, takeLatest) as Saga
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

tick :: ∀ m. MonadAff m => SagaT State Action m Unit
tick = do
  waitTime <- Saga.takeEvery case _ of
        ActionTock wait -> Just wait
        _ -> Nothing
  
  liftAff $ delay (Milliseconds waitTime)
  Saga.put (ActionTick 500.0)
  
  tickCount <- Saga.select _.tickCount
  liftEffect $ log $ "tick " <> show tickCount
    

tock :: ∀ m. MonadAff m => SagaT State Action m Unit
tock = do
  waitTime <- Saga.takeEvery case _ of
      ActionTick wait -> Just wait
      _ -> Nothing
  
  liftAff $ delay (Milliseconds waitTime)
  Saga.put (ActionTock 1000.0)
  
  tockCount <- Saga.select _.tockCount
  liftEffect $ log $ "tock " <> show tockCount

main :: Effect Unit
main = launchAff_ do
  actionBus <- Bus.make
  stateBus <- Bus.make

  Saga.run actionBus stateBus [raceRunner]

  let rootReducer = Saga.rootReducer stateBus reduce :: SagaT State Action Aff Unit
  Saga.run actionBus stateBus [rootReducer, tick, tock, guarded, latestTick, latestTock]
  Bus.write initState stateBus
  Bus.write (ActionTick 500.0) actionBus

  Aff.delay (Milliseconds 5000.0)
  Bus.kill (Aff.error "end") actionBus
  Bus.kill (Aff.error "end") stateBus

raceRunner :: ∀ s a. SagaT s a Aff Unit
raceRunner = do
  res <- raceA <|> raceB
  liftEffect $ log $ "race winner " <> res

  where
  raceA ::SagaT s a Aff String
  raceA = do
      liftAff $ delay (Milliseconds 1000.0)
      pure "A"

  raceB :: SagaT s a Aff String
  raceB = do
      liftAff $ delay (Milliseconds 500.0)
      pure "B"

guarded :: SagaT State Action Aff Unit
guarded = do
    cntVar <- liftAff $ AVar.new 0
    wait <- Saga.takeEvery case _ of
        ActionTick w -> Just w
        _ -> Nothing
    cnt <- liftAff do
      c <- AVar.take cntVar
      AVar.put (c + 1) cntVar
      pure (c + 1)
    
    guard (cnt > 2)

    inState <- Saga.select _.tickCount

    liftEffect $ log $ "Guard finished " <> show inState

latestTick :: ∀ s m. MonadAff m => SagaT s Action m Unit
latestTick = do
  res <- Saga.takeLatest case _ of
    ActionTick _ -> Just unit
    _ -> Nothing
    
  case res of
    Superseded -> liftEffect $ log "Superseded tick"
    Latest _ -> do
      liftAff $ Aff.delay (Milliseconds 10000.0) -- will be always superseded
      liftEffect $ log "latest tick"

latestTock :: ∀ s m. MonadAff m => SagaT s Action m Unit
latestTock = do
  res <- Saga.takeLatest case _ of
    ActionTick _ -> Just unit
    _ -> Nothing
    
  case res of
    Superseded -> liftEffect $ log "Superseded tock"
    Latest _ -> do
      liftAff $ Aff.delay (Milliseconds 100.0)      
      liftEffect $ log "latest tock"
