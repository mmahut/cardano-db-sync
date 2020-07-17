{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeSynonymInstances #-}

module Cardano.DbSync.DbAction
  ( DbAction (..)
  , DbActionQueue (..)
  , MkDbAction (..)
  , blockingFlushDbActionQueue
  , lengthDbActionQueue
  , newDbActionQueue
  , writeDbActionQueue
  ) where

import           Cardano.Prelude

import           Cardano.DbSync.Types

import qualified Control.Concurrent.STM as STM
import           Control.Concurrent.STM.TBQueue (TBQueue)
import qualified Control.Concurrent.STM.TBQueue as TBQ

import           Ouroboros.Consensus.Byron.Ledger (ByronBlock (..))
import           Ouroboros.Consensus.Cardano.Block (CardanoBlock, HardForkBlock (..))
import           Ouroboros.Consensus.Shelley.Ledger.Block (ShelleyBlock)
import           Ouroboros.Consensus.Shelley.Protocol (TPraosStandardCrypto)
import           Ouroboros.Network.Block (Point (..))

data DbAction
  = DbApplyBlock !CardanoBlockTip
  | DbRollBackToPoint !CardanoPoint
  | DbFinish


newtype DbActionQueue = DbActionQueue
  { dbActQueue :: TBQueue DbAction
  }

class MkDbAction blk where
  mkDbApply :: blk -> DbAction
  mkDbRollback :: Point blk -> DbAction


instance MkDbAction ByronBlock where
  mkDbApply blk = DbApplyBlock (ByronBlockTip blk)
  mkDbRollback point = DbRollBackToPoint (ByronPoint point)

instance MkDbAction (ShelleyBlock TPraosStandardCrypto) where
  mkDbApply blk = DbApplyBlock (ShelleyBlockTip blk)
  mkDbRollback point = DbRollBackToPoint (ShelleyPoint point)

instance MkDbAction (CardanoBlock TPraosStandardCrypto) where
  mkDbApply cblk = do
    case cblk of
      BlockByron blk -> DbApplyBlock (ByronBlockTip blk)
      BlockShelley blk -> DbApplyBlock (ShelleyBlockTip blk)

  mkDbRollback point =
      DbRollBackToPoint (CardanoPoint point)



lengthDbActionQueue :: DbActionQueue -> STM Natural
lengthDbActionQueue (DbActionQueue q) = STM.lengthTBQueue q

newDbActionQueue :: IO DbActionQueue
newDbActionQueue = DbActionQueue <$> TBQ.newTBQueueIO 2000

writeDbActionQueue :: DbActionQueue -> DbAction -> STM ()
writeDbActionQueue (DbActionQueue q) = TBQ.writeTBQueue q

-- | Block if the queue is empty and if its not read/flush everything.
-- Need this because `flushTBQueue` never blocks and we want to block until
-- there is one item or more.
-- Use this instead of STM.check to make sure it blocks if the queue is empty.
blockingFlushDbActionQueue :: DbActionQueue -> IO [DbAction]
blockingFlushDbActionQueue (DbActionQueue queue) = do
  STM.atomically $ do
    x <- TBQ.readTBQueue queue
    xs <- TBQ.flushTBQueue queue
    pure $ x : xs
