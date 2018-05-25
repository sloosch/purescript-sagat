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
import Control.Monad.Aff (Canceler(..), Fiber, cancelWith, forkAff)
import Control.Monad.Aff as Aff
import Control.Monad.Aff.AVar (AVAR, AVar)
import Control.Monad.Aff.AVar as AVar
import Control.Monad.Aff.Bus (BusR', BusRW)
import Control.Monad.Aff.Bus as Bus
import Control.Monad.Aff.Class (class MonadAff, liftAff)
import Control.Monad.Eff.Class (class MonadEff)
import Control.Monad.Free.Trans (FreeT, hoistFreeT, liftFreeT)
import Control.Monad.Free.Trans as Free
import Control.Monad.IO (INFINITY, IO, runIO')
import Control.Monad.IO.Class (class MonadIO, liftIO)
import Control.Monad.IOSync.Class (class MonadIOSync, liftIOSync)
import Control.Monad.Maybe.Trans (class MonadTrans, lift, runMaybeT)
import Control.Monad.Reader (ReaderT, ask, mapReaderT, runReaderT)
import Control.Monad.Rec.Class (class MonadRec)
import Control.Monad.Saga.ForkPool (ForkPool)
import Control.Monad.Saga.ForkPool as ForkPool
import Control.Monad.Saga.Runnable (class Runnable, runAsIO)
import Control.MonadZero (class MonadZero)
import Data.Either (Either(..), either)
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
  | Never
derive instance functorSagaF :: Functor (SagaF s action)

type SagaCtx s action = {
  latestState :: AVar s,
  actionBus :: BusRW action,
  forkPool :: ForkPool
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
instance monadIOSagaT :: MonadIO m => MonadIO (SagaT s action m) where
  liftIO = lift <<< liftIO
instance monadIOSyncSagaT :: MonadIOSync m => MonadIOSync (SagaT s action m) where
  liftIOSync = lift <<< liftIOSync

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

run :: ∀ m a s r z f. Foldable f => Runnable m => BusRW a -> BusR' z s -> f (SagaT s a m r) -> IO Unit
run actionBus stateBus sagas = liftAff do
  latestState <- AVar.makeEmptyVar
  suspended <- AVar.makeEmptyVar
  forkPool <- ForkPool.make top
  let
    stateLoop = do
        s <- Bus.read stateBus
        _ <- AVar.tryTakeVar latestState
        AVar.putVar s latestState
        stateLoop
  _ <- forkAff stateLoop
  
  traverse_ (forkAff <<< runIO' <<< runSagaT {latestState, actionBus, forkPool}) sagas


runSagaT :: ∀ a s r m. Runnable m => SagaCtx s a -> SagaT s a m r -> IO r
runSagaT sctx sagat =
 resumeSaga sctx $ runReaderT (unwrap $ hoistSagaT runAsIO sagat) sctx
  where
  resumeSaga :: SagaCtx s a -> FreeT (SagaF s a) IO r -> IO r
  resumeSaga ctx saga = Free.resume saga >>= case _ of
      Left r -> pure r
      Right step -> interpret ctx step

  interpret :: SagaCtx s a -> SagaF s a (FreeT (SagaF s a) IO r) -> IO r
  interpret ctx (Take matches) = loop where
    loop = matches <$> (liftAff $ Bus.read ctx.actionBus) >>= case _ of
      Just step -> resumeSaga ctx step
      Nothing -> loop
  interpret ctx (TakeEvery matches) = loop where
    loop = do
      _ <- runMaybeT do
        step <- wrap $ liftAff $ matches <$> Bus.read ctx.actionBus
        ForkPool.add ctx.forkPool $ resumeSaga ctx step
      loop
  interpret ctx (TakeLatest (TakeLatestF q)) = liftAff do
    prevProcess <- AVar.makeEmptyVar
    let loop = do
          _ <- runMaybeT do
            step <- wrap $ q.test <$> Bus.read ctx.actionBus
            lift do
              _ <- runMaybeT do
                process <- wrap $ AVar.tryTakeVar prevProcess
                lift $ Aff.killFiber (Aff.error "[saga] superseded") process
              newProcess <- ForkPool.add ctx.forkPool $ ((runIO' $ resumeSaga ctx step) `cancelWith` cancelPath)
              AVar.putVar newProcess prevProcess
          loop
    loop
    where
    cancelPath = Canceler $ const $ void $ runIO' $ resumeSaga ctx q.cancel    
    
  interpret ctx (Put a step) = liftAff do
    Bus.write a ctx.actionBus
    runIO' $ resumeSaga ctx step
  interpret ctx (Select step) = do
    state <- liftAff $ AVar.readVar ctx.latestState
    resumeSaga ctx $ step state
  interpret ctx Never = liftAff Aff.never

fork :: ∀ s a m r n. MonadAff _ m => Runnable n => SagaT s a n r -> SagaT s a m (Fiber _ r)
fork saga = do
  ctx <- SagaT ask
  ForkPool.add ctx.forkPool $ runSagaT ctx saga

race :: ∀ s a m u v. MonadAff _ m => Runnable m => SagaT s a m u -> SagaT s a m v -> SagaT s a m (Either u v)
race s1 s2 = do
  ctx <- SagaT ask
  res <- liftAff $ AVar.makeEmptyVar
  f1 <- fork do
    r <- s1
    liftAff $ AVar.putVar (Left r) res
  f2 <- fork do
    r <- s2
    liftAff $ AVar.putVar (Right r) res
  
  liftAff do
    fin <- AVar.takeVar res
    traverse_ (Aff.killFiber $ Aff.error "[saga] race done") [f1, f2]
    pure fin

type Fx e = (avar :: AVAR, infinity :: INFINITY | e)

instance sagaIOAlt :: (Runnable m, MonadAff (Fx e) m) => Alt (SagaT s a m) where
  alt s1 s2 = do
    res <- race s1 s2
    pure $ either id id res

instance sagaIOPlus :: (Runnable m, MonadAff (Fx e) m) => Plus (SagaT s a m) where
  empty = SagaT $ lift $ liftFreeT $ Never  
instance sagaIOAlternative ::(Runnable m, MonadAff (Fx e) m) => Alternative (SagaT s a m)
instance sagaIOMonadZero ::(Runnable m, MonadAff (Fx e) m) => MonadZero (SagaT s a m)
