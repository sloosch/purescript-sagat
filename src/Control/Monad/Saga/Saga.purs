module Control.Monad.Saga (
   SagaT,
   SagaCtx,
   SagaF,
   TakeLatestResult(..),
   take,
   takeEvery,
   takeLatest,
   put,
   select,
   fork,
   run,
   hoistSagaT,
   race
  ) where

import Prelude

import Control.Alt (class Alt)
import Control.Alternative (class Alternative, class Plus)
import Control.Monad.Aff.Bus (BusR', BusRW)
import Control.Monad.Aff.Bus as Bus
import Control.Monad.Free.Trans (FreeT, hoistFreeT, liftFreeT)
import Control.Monad.Free.Trans as Free
import Control.Monad.Maybe.Trans (class MonadTrans, lift, runMaybeT)
import Control.Monad.Reader (ReaderT, ask, mapReaderT, runReaderT)
import Control.Monad.Rec.Class (class MonadRec)
import Control.Monad.Saga.ForkPool (ForkPool)
import Control.Monad.Saga.ForkPool as ForkPool
import Control.MonadZero (class MonadZero)
import Data.Either (Either(..), either)
import Data.Foldable (class Foldable, traverse_)
import Data.Maybe (Maybe(..))
import Data.Newtype (class Newtype, unwrap, wrap)
import Effect.Aff (Aff, Canceler(..), Fiber, cancelWith, forkAff)
import Effect.Aff as Aff
import Effect.Aff.AVar (AVar)
import Effect.Aff.AVar as AVar
import Effect.Aff.Class (class MonadAff, liftAff)
import Effect.Class (class MonadEffect)

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
  | Never
derive instance functorSagaF :: Functor (SagaF s action)

type SagaCtx s action = {
  latestState :: AVar s,
  actionBus :: BusRW action,
  forkPool :: ForkPool
}
newtype SagaT s action m a = SagaT (ReaderT (SagaCtx s action) (FreeT (SagaF s action) m) a)
derive instance newtypeSagaT :: Newtype (SagaT s a m r) _
derive newtype instance functorSagaT :: Functor m => Functor (SagaT s action m)
derive newtype instance applicativeSagaT ::Monad m => Applicative (SagaT s action m)
derive newtype instance applySagaT ::Monad m => Apply (SagaT s action m)
derive newtype instance bindSagaT :: Monad m => Bind (SagaT s action m)
derive newtype instance monadSagaT ::Monad m => Monad (SagaT s action m)
derive newtype instance monadEffSagaT :: MonadEffect m => MonadEffect (SagaT s action m)
derive newtype instance monadRecSagaT :: MonadRec m => MonadRec (SagaT s action m)
instance monadTransSagaT :: MonadTrans (SagaT s action) where
  lift = SagaT <<< lift <<< lift
instance monadAffSagaT :: MonadAff m => MonadAff (SagaT s action m) where
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

hoistSagaT :: ∀ m n s a. Functor m => Functor n => (m ~> n) -> SagaT s a m ~> SagaT s a n
hoistSagaT f (SagaT saga) = SagaT $ mapReaderT (hoistFreeT f) saga

run :: ∀ a s r z f. Foldable f => BusRW a -> BusR' z s -> f (SagaT s a Aff r) -> Aff Unit
run actionBus stateBus sagas = liftAff do
  latestState <- AVar.empty
  forkPool <- ForkPool.make top
  let
    stateLoop = (Aff.attempt $ Bus.read stateBus) >>= case _ of 
        Left _ -> pure unit
        Right s -> do
          _ <- AVar.tryTake latestState
          AVar.put s latestState
          stateLoop
  _ <- forkAff stateLoop
  
  traverse_ (forkAff <<< runSagaT {latestState, actionBus, forkPool}) sagas

runSagaT :: ∀ a s r. SagaCtx s a -> SagaT s a Aff r -> Aff (Either Aff.Error r)
runSagaT sctx sagat =
 resumeSaga $ runReaderT (unwrap sagat) sctx
  where

  action :: ∀ n. MonadAff n => n (Either Aff.Error a)
  action = liftAff $ Aff.attempt $ Bus.read sctx.actionBus

  actionMatchLoop :: ∀ p n. MonadAff n => (a -> Maybe p) -> (p -> n (Either Aff.Error r)) -> n (Either Aff.Error r)
  actionMatchLoop test f = map test <$> action >>= case _ of
      Left err -> pure $ Left err 
      Right res -> case res of
        Just step -> f step
        Nothing -> actionMatchLoop test f

  resumeSaga :: FreeT (SagaF s a) Aff r -> Aff (Either Aff.Error r)
  resumeSaga saga = Free.resume saga >>= case _ of
      Left r -> pure $ Right r
      Right step -> interpret step

  interpret ::SagaF s a (FreeT (SagaF s a) Aff r) -> Aff (Either Aff.Error r)
  interpret (Take test) = 
    actionMatchLoop test resumeSaga
  interpret (TakeEvery test) = loop where
    loop = actionMatchLoop test \step -> do
          _ <- ForkPool.add sctx.forkPool $ resumeSaga step
          loop
  interpret (TakeLatest (TakeLatestF q)) = do
    prevProcess <- AVar.empty
    let loop = actionMatchLoop q.test \step -> do
                _ <- runMaybeT do
                  process <- wrap $ AVar.tryTake prevProcess
                  lift $ Aff.killFiber (Aff.error "[saga] superseded") process
                newProcess <- ForkPool.add sctx.forkPool $ (resumeSaga step) `cancelWith` cancelPath
                AVar.put newProcess prevProcess
                loop
    loop
    where
    cancelPath = Canceler $ const $ void $ resumeSaga q.cancel    
    
  interpret (Put a step) = do
    res <- Aff.attempt $ Bus.write a sctx.actionBus
    case res of
      Left err -> pure $ Left err
      Right _ -> resumeSaga step
  interpret (Select step) = do
    state <-  AVar.read sctx.latestState
    resumeSaga $ step state
  interpret Never = Aff.never

fork :: ∀ s a m r. MonadAff m => SagaT s a Aff r -> SagaT s a m (Fiber (Either Aff.Error r))
fork saga = do
  ctx <- SagaT ask
  ForkPool.add ctx.forkPool $ runSagaT ctx saga

race :: ∀ s a m u v. MonadAff m => SagaT s a Aff u -> SagaT s a Aff v -> SagaT s a m (Either u v)
race s1 s2 = do
  ctx <- SagaT ask
  res <- liftAff $ AVar.empty
  f1 <- fork do
    r <- s1
    liftAff $ AVar.put (Left r) res
  f2 <- fork do
    r <- s2
    liftAff $ AVar.put (Right r) res
  
  liftAff do
    fin <- AVar.take res
    traverse_ (Aff.killFiber $ Aff.error "[saga] race done") [f1, f2]
    pure fin

instance sagaIOAlt :: Alt (SagaT s a Aff) where
  alt s1 s2 = do
    res <- race s1 s2
    pure $ either identity identity res

instance sagaIOPlus :: Plus (SagaT s a Aff) where
  empty = SagaT $ lift $ liftFreeT $ Never  
instance sagaIOAlternative :: Alternative (SagaT s a Aff)
instance sagaIOMonadZero :: MonadZero (SagaT s a Aff)
