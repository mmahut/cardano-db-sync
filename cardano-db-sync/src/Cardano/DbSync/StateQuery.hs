{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}

module Cardano.DbSync.StateQuery
  ( StateQueryTMVar -- Opaque, so it cannot be misused.
  , getSlotDetails
  , localStateQueryHandler
  , newStateQueryTMVar
  ) where

import           Cardano.BM.Trace (Trace, logInfo)

import           Cardano.Slotting.Slot (SlotNo (..))

import           Cardano.DbSync.Config.Types
import           Cardano.DbSync.Types
import           Cardano.DbSync.Util

import           Cardano.Prelude

import           Control.Concurrent.STM.TMVar (TMVar, newEmptyTMVarIO, putTMVar, takeTMVar)

import           Data.IORef (IORef, newIORef, readIORef, writeIORef)
import           Data.Time.Clock (UTCTime, addUTCTime, getCurrentTime)

import           Ouroboros.Consensus.BlockchainTime.WallClock.Types (RelativeTime (..),
                   SystemStart (..))
import           Ouroboros.Consensus.Cardano.Block (CardanoEras, Query (..))
import           Ouroboros.Consensus.Cardano.Node ()
import           Ouroboros.Consensus.HardFork.Combinator.Basics (HardForkBlock (..))
import           Ouroboros.Consensus.HardFork.Combinator.Ledger.Query
                   (QueryHardFork (GetInterpreter))
import           Ouroboros.Consensus.HardFork.History.Qry (Expr (..), Interpreter,
                   PastHorizonException, Qry, interpretQuery, qryFromExpr, slotToEpoch')
import           Ouroboros.Consensus.Shelley.Protocol (StandardCrypto)

import           Ouroboros.Network.Block (Point (..))
import           Ouroboros.Network.Protocol.LocalStateQuery.Client (ClientStAcquired (..),
                   ClientStAcquiring (..), ClientStIdle (..), ClientStQuerying (..),
                   LocalStateQueryClient (..))
import qualified Ouroboros.Network.Protocol.LocalStateQuery.Client as StateQuery
import           Ouroboros.Network.Protocol.LocalStateQuery.Type (AcquireFailure)

import           System.IO.Unsafe (unsafePerformIO)

newtype StateQueryTMVar blk result = StateQueryTMVar
  { unStateQueryTMVar ::
      TMVar
        ( Point blk
        , Query blk result
        , TMVar (Either AcquireFailure result)
        )
  }

newStateQueryTMVar :: IO (StateQueryTMVar blk result)
newStateQueryTMVar = StateQueryTMVar <$> newEmptyTMVarIO


-- Get the requested slot details using a history interpreter stashed in an IORef.
-- If the history interpreter does not exist, get one.
-- If the existing history interpreter returns an error, get a new one and try again.
getSlotDetails
    :: Trace IO Text -> DbSyncEnv
    -> StateQueryTMVar (HardForkBlock (CardanoEras StandardCrypto)) (Interpreter (CardanoEras StandardCrypto))
    -> Point (HardForkBlock (CardanoEras StandardCrypto)) -> SlotNo
    -> IO SlotDetails
getSlotDetails tracer env queryVar point slot = do
    einterp1 <- maybe (getHistoryInterpreter tracer queryVar point) pure =<< readIORef historyInterpVar
    case evalSlotDetails einterp1 of
      Right sd -> insertCurrentTime sd
      Left _ -> do
        einterp2 <- getHistoryInterpreter tracer queryVar point
        case evalSlotDetails einterp2 of
          Left err -> panic $ "getSlotDetails: " <> textShow err
          Right sd -> insertCurrentTime sd
  where
    evalSlotDetails :: Interpreter (CardanoEras StandardCrypto) -> Either PastHorizonException SlotDetails
    evalSlotDetails interp =
      interpretQuery interp (querySlotDetails (envSystemStart env) slot)

    insertCurrentTime :: SlotDetails -> IO SlotDetails
    insertCurrentTime sd = do
      time <- getCurrentTime
      pure $ sd { sdCurrentTime = time }

-- -------------------------------------------------------------------------------------------------

{-# NOINLINE historyInterpVar #-}
historyInterpVar :: IORef (Maybe (Interpreter (CardanoEras StandardCrypto)))
historyInterpVar = unsafePerformIO $ newIORef Nothing

getHistoryInterpreter
    :: Trace IO Text
    -> StateQueryTMVar (HardForkBlock (CardanoEras StandardCrypto)) (Interpreter (CardanoEras StandardCrypto))
    -> Point (HardForkBlock (CardanoEras StandardCrypto))
    -> IO (Interpreter (CardanoEras StandardCrypto))
getHistoryInterpreter tracer queryVar point = do
  respVar <- newEmptyTMVarIO
  atomically $ putTMVar (unStateQueryTMVar queryVar) (point, QueryHardFork GetInterpreter, respVar)
  res <- atomically $ takeTMVar respVar
  case res of
    Left err ->
      panic $ "getHistoryInterpreter: " <> textShow err
    Right interp -> do
      logInfo tracer "getHistoryInterpreter: acquired"
      writeIORef historyInterpVar $ Just interp
      pure interp


-- This is called during the ChainSync setup and loops forever. Queries can be posted to
-- it and responses retrieved via a TVar.
localStateQueryHandler
    :: forall block result a
    . StateQueryTMVar block result
    -> LocalStateQueryClient block (Query block) IO a
localStateQueryHandler (StateQueryTMVar reqVar) =
    LocalStateQueryClient idleState
  where
    idleState :: IO (StateQuery.ClientStIdle block (Query block) IO a)
    idleState = do
      (point, query, respVar) <- atomically $ takeTMVar reqVar
      pure $
        SendMsgAcquire point $
          ClientStAcquiring
            { recvMsgAcquired =
                SendMsgQuery query $
                  ClientStQuerying
                    { recvMsgResult = \result -> do
                        atomically $ putTMVar respVar (Right result)
                        pure $ SendMsgRelease idleState
                    }
            , recvMsgFailure = \failure -> do
                atomically $ putTMVar respVar (Left failure)
                idleState
            }

-- -------------------------------------------------------------------------------------------------

-- TODO: Switch back to the old version of this when this is fixed:
-- https://github.com/input-output-hk/cardano-db-sync/issues/276
querySlotDetails :: SystemStart -> SlotNo -> Qry SlotDetails
querySlotDetails start absSlot = do
  absTime <- qryFromExpr $
                ELet (EAbsToRelSlot (ELit absSlot)) $ \ relSlot ->
                ELet (ERelSlotToTime (EVar relSlot)) $ \ relTime ->
                ELet (ERelToAbsTime (EVar relTime)) $ \ absTime ->
                EVar absTime
  (absEpoch, slotInEpoch) <- slotToEpoch' absSlot
  epochSize <- qryFromExpr $ EEpochSize (ELit absEpoch)
  let time = relToUTCTime start absTime
  -- Set sdCurrentTime below and over write that above.
  pure $ SlotDetails time time absEpoch (EpochSlot slotInEpoch) epochSize

relToUTCTime :: SystemStart -> RelativeTime -> UTCTime
relToUTCTime (SystemStart start) (RelativeTime rel) = addUTCTime rel start
