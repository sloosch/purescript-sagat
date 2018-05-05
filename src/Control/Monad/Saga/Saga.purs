module Control.Monad.Saga (
   SagaT,
   TakeLatestResult(..),
   take,
   takeEvery,
   takeLatest,
   put,
   select,
   fork,
   run,
   hoistSaga
  ) where

import Prelude

import Control.Monad.Aff (Aff, Canceler(..), Fiber, cancelWith, forkAff)
import Control.Monad.Aff as Aff
import Control.Monad.Aff.AVar (AVar)
import Control.Monad.Aff.AVar as AVar
import Control.Monad.Aff.Bus (BusRW, BusR')
import Control.Monad.Aff.Bus as Bus
import Control.Monad.Aff.Class (class MonadAff, liftAff)
import Control.Monad.Eff.Class (class MonadEff)
import Control.Monad.Free.Trans (FreeT, hoistFreeT, liftFreeT)
import Control.Monad.Free.Trans as Free
import Control.Monad.Maybe.Trans (class MonadTrans, lift, runMaybeT)
import Control.Monad.Reader (ReaderT, ask, mapReaderT, runReaderT)
import Control.Monad.Rec.Class (class MonadRec)
import Data.Either (Either(..))
import Data.Foldable (class Foldable, traverse_)
import Data.Maybe (Maybe(..))
import Data.Newtype (class Newtype, unwrap, wrap)


data TakeLatestResult a = Superseded | Latest a
derive instance functorTakeLatestResult :: Functor (TakeLatestResult)
instance showTakeLatestResult :: Show a => Show (TakeLatestResult a) where
  show (Superseded) = "Superseded"
  show (Latest a) = "Latest: " <> show a

newtype TakeLatestF action a = TakeLatestF {cancel :: a, test :: action -> Maybe a}
instance takeLatestFunctor :: Functor (TakeLatestF action) where
  map f (TakeLatestF q) = TakeLatestF {cancel: f q.cancel, test: map f <<< q.test}


data SagaF s action a =
    Take (action -> Maybe a)
  | TakeEvery (action -> Maybe a)
  | TakeLatest (TakeLatestF action a)
  | Put action a
  | Select (s -> a)
derive instance functorSagaF :: Functor (SagaF s action)

type SagaCtx s action = {
  latestState :: AVar s,
  actionBus :: BusRW action
}
newtype SagaT s action m a = SagaT (ReaderT (SagaCtx s action) (FreeT (SagaF s action) m) a)
derive instance newtypeSagaT :: Newtype (SagaT s action m a) _
derive newtype instance functorSagaT :: Functor m => Functor (SagaT s action m)
derive newtype instance applicativeSagaT ::Monad m => Applicative (SagaT s action m)
derive newtype instance applySagaT ::Monad m => Apply (SagaT s action m)
derive newtype instance bindSagaT :: Monad m => Bind (SagaT s action m)
derive newtype instance monadSagaT ::Monad m => Monad (SagaT s action m)
derive newtype instance monadEffSagaT :: MonadEff e m => MonadEff e (SagaT s action m)
derive newtype instance monadRecSagaT :: MonadRec m => MonadRec (SagaT s action m)
instance monadTransSagaT :: MonadTrans (SagaT s action) where
  lift = SagaT <<< lift <<< lift
instance monadAffSagaT :: MonadAff e m => MonadAff e (SagaT s action m) where
  liftAff = lift <<< liftAff

take :: ∀ s action payload m. Monad m => (action -> Maybe payload) -> SagaT s action m payload
take f = SagaT $ lift $ liftFreeT $ Take f

takeEvery :: ∀ s action payload m. Monad m => (action -> Maybe payload) -> SagaT s action m payload
takeEvery f = SagaT $ lift $ liftFreeT $ TakeEvery f

takeLatest :: ∀ s action payload m. Monad m => (action -> Maybe payload) -> SagaT s action m (TakeLatestResult payload)
takeLatest f = SagaT $ lift $ liftFreeT $ TakeLatest $ TakeLatestF {cancel: Superseded, test: map Latest <<< f}

put :: ∀ s action m. Monad m => action -> SagaT s action m Unit
put action = SagaT $ lift $ liftFreeT $ Put action unit

select :: ∀ s s' action m. Monad m => (s -> s') -> SagaT s action m s'
select f = SagaT $ lift $ liftFreeT $ Select f

fork :: ∀ s a m r. MonadAff _ m => SagaT s a (Aff _) r -> SagaT s a m (Fiber _ r)
fork saga = do
  ctx <- SagaT ask
  liftAff $ forkAff $ runSagaT ctx saga

hoistSaga :: ∀ m n s a. Functor m => Functor n => (m ~> n) -> SagaT s a m ~> SagaT s a n
hoistSaga f (SagaT saga) = SagaT $ mapReaderT (hoistFreeT f) saga

run :: ∀ a s r z f. Foldable f => BusRW a -> BusR' z s -> f (SagaT s a (Aff _) r) -> Aff _ Unit
run actionBus stateBus sagas = do
  latestState <- AVar.makeEmptyVar
  let
    loop = do
        s <- Bus.read stateBus
        _ <- AVar.tryTakeVar latestState
        AVar.putVar s latestState
        loop
  _ <- forkAff loop
  traverse_ (forkAff <<< runSagaT {latestState, actionBus}) sagas


runSagaT :: ∀ a s r. SagaCtx s a -> SagaT s a (Aff _) r -> Aff _ r
runSagaT ctx@{latestState, actionBus} sagat =
 resumeSaga latestState $ runReaderT (unwrap sagat) ctx

  where
  resumeSaga :: AVar s -> FreeT (SagaF s a) (Aff _) r -> Aff _ r
  resumeSaga var saga = Free.resume saga >>= case _ of
      Left r -> pure r
      Right step -> interpret var step

  interpret :: AVar s -> SagaF s a (FreeT (SagaF s a) (Aff _) r) -> Aff _ r
  interpret var (Take matches) = loop where
    loop = matches <$> Bus.read actionBus >>= case _ of
        Just step -> resumeSaga var step
        Nothing -> loop
  interpret var (TakeEvery matches) = loop where
    loop = matches <$> Bus.read actionBus >>= case _ of
        Just step -> forkAff (resumeSaga var step) *> loop
        Nothing -> loop
  interpret var (TakeLatest (TakeLatestF q)) = do
    prevProcess <- AVar.makeEmptyVar
    let loop = do
          _ <- runMaybeT do
            step <- wrap $ q.test <$> Bus.read actionBus
            lift do
              _ <- runMaybeT do
                process <- wrap $ AVar.tryTakeVar prevProcess
                lift $ Aff.killFiber (Aff.error "[saga] superseded") process
              newProcess <- forkAff $ resumeSaga var step `cancelWith` (Canceler $ const $ void $ resumeSaga var q.cancel)
              AVar.putVar newProcess prevProcess
          loop
    loop
  interpret var (Put a step) = Bus.write a actionBus *> resumeSaga var step
  interpret var (Select step) = (step <$> AVar.readVar var) >>= resumeSaga var