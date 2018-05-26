module Control.Monad.Saga.Reducer where

import Prelude

import Effect.Aff as Aff
import Control.Monad.Aff.Bus (BusW')
import Control.Monad.Aff.Bus as Bus
import Effect.Aff.Class (class MonadAff, liftAff)
import Control.Monad.Saga (SagaT)
import Control.Monad.Saga as Saga
import Data.Maybe (Maybe(..))

rootReducer :: ∀ s a m z. MonadAff m => BusW' z s -> (a -> s -> s) -> SagaT s a m Unit
rootReducer stateBus f = do
    newState <- f <$> Saga.takeEvery Just <*> Saga.select identity
    liftAff $ Aff.apathize $ Bus.write newState stateBus
