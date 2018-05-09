module Control.Monad.Saga.Reducer where

import Prelude

import Control.Monad.Aff.Bus (BusW')
import Control.Monad.Aff.Bus as Bus
import Control.Monad.Aff.Class (class MonadAff, liftAff)
import Control.Monad.Saga (SagaT)
import Control.Monad.Saga as Saga
import Data.Maybe (Maybe(..))

rootReducer :: ∀ s a m z. MonadAff _ m => BusW' z s -> (a -> s -> s) -> SagaT s a m Unit
rootReducer stateBus f = do
    newState <- f <$> Saga.takeEvery Just <*> Saga.select id
    liftAff $ Bus.write newState stateBus
