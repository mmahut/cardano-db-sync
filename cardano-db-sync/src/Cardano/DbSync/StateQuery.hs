{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Cardano.DbSync.StateQuery
  ( StateQueryTMVar (..)
  , localStateQueryHandler
  ) where

import           Control.Tracer (Tracer)

import           Control.Monad.IO.Class (MonadIO, liftIO)
import           Control.Monad.Class.MonadSTM.Strict (StrictTMVar (..), takeTMVar, putTMVar)

import qualified Cardano.BM.Setup as Logging
import           Cardano.BM.Data.Tracer (ToLogObject (..))
import           Cardano.BM.Trace (Trace, appendName, logInfo)
import qualified Cardano.BM.Trace as Logging

import           Cardano.Client.Subscription (subscribe)
import qualified Cardano.Crypto as Crypto

import           Cardano.Db (LogFileDir (..))
import qualified Cardano.Db as DB
import           Cardano.DbSync.Config
import           Cardano.DbSync.Database
import           Cardano.DbSync.Era
import           Cardano.DbSync.Error
import           Cardano.DbSync.Metrics
import           Cardano.DbSync.Plugin (DbSyncNodePlugin (..))
import           Cardano.DbSync.Plugin.Default (defDbSyncNodePlugin)
import           Cardano.DbSync.Plugin.Default.Rollback (unsafeRollback)
import           Cardano.DbSync.Tracing.ToObjectOrphans ()
import           Cardano.DbSync.Types
import           Cardano.DbSync.Util

import           Cardano.Prelude hiding (atomically, option, (%), Nat)

import           Cardano.Slotting.Slot (SlotNo (..), WithOrigin (..))

import qualified Codec.CBOR.Term as CBOR
import           Control.Monad.Class.MonadSTM.Strict (atomically)
import           Control.Monad.Class.MonadTimer (MonadTimer)
import           Control.Monad.IO.Class (liftIO)
import           Control.Monad.Trans.Except.Exit (orDie)

import qualified Data.ByteString.Lazy as BSL
import           Data.Text (Text)
import qualified Data.Text as Text
import           Data.Void (Void)

import           Network.TypedProtocol.Core (Peer)
import           Network.Mux (MuxTrace, WithMuxBearer)
import           Network.Mux.Types (MuxMode (..))

import           Ouroboros.Network.Driver.Simple (runPipelinedPeer)
import           Network.TypedProtocol.Pipelined (Nat(Zero, Succ))

import           Ouroboros.Consensus.Block.Abstract (CodecConfig, ConvertRawHash (..))
import           Ouroboros.Consensus.Byron.Ledger.Config (mkByronCodecConfig)
import           Ouroboros.Consensus.Byron.Node ()
import           Ouroboros.Consensus.Cardano.Block (CodecConfig (..), Query (..))
import           Ouroboros.Consensus.Cardano.Node ()
import           Ouroboros.Consensus.Network.NodeToClient (ClientCodecs,
                    cChainSyncCodec, cStateQueryCodec, cTxSubmissionCodec)
import           Ouroboros.Consensus.Node.ErrorPolicy (consensusErrorPolicy)
import           Ouroboros.Consensus.Node.Run (RunNode)
import           Ouroboros.Consensus.Shelley.Ledger.Block (ShelleyBlock)
import           Ouroboros.Consensus.Shelley.Ledger.Config (CodecConfig (ShelleyCodecConfig))
import           Ouroboros.Consensus.Shelley.Protocol (TPraosStandardCrypto)

import           Ouroboros.Network.Magic (NetworkMagic)
import qualified Ouroboros.Network.NodeToClient.Version as Network
import           Ouroboros.Network.Block (BlockNo (..), HeaderHash, Point (..),
                    Tip, genesisPoint, getTipBlockNo, blockNo)
import           Ouroboros.Network.Mux (MuxPeer (..),  RunMiniProtocol (..))
import           Ouroboros.Network.NodeToClient
                   (NodeToClientProtocols(..), NodeToClientVersionData(..),
                    NetworkConnectTracers(..), withIOManager, connectTo,
                    localSnocket, foldMapVersions,
                    versionedNodeToClientProtocols, chainSyncPeerNull,
                    localTxSubmissionPeerNull, localStateQueryPeerNull)

import           Ouroboros.Network.NodeToClient (IOManager, ClientSubscriptionParams (..),
                    ConnectionId, ErrorPolicyTrace (..), Handshake, LocalAddress,
                    NetworkSubscriptionTracers (..), NodeToClientProtocols (..),
                    TraceSendRecv, WithAddr (..), localSnocket, localTxSubmissionPeerNull,
                    networkErrorPolicies, withIOManager)
import qualified Ouroboros.Network.Point as Point
import           Ouroboros.Network.Point (withOrigin)
import           Ouroboros.Network.Protocol.LocalStateQuery.Type (LocalStateQuery)
import           Ouroboros.Consensus.Ledger.SupportsMempool (ApplyTxErr)

import           Ouroboros.Network.Protocol.ChainSync.ClientPipelined (ChainSyncClientPipelined (..),
                    ClientPipelinedStIdle (..), ClientPipelinedStIntersect (..), ClientStNext (..),
                    chainSyncClientPeerPipelined, recvMsgIntersectFound, recvMsgIntersectNotFound,
                    recvMsgRollBackward, recvMsgRollForward)
import           Ouroboros.Network.Protocol.ChainSync.PipelineDecision (pipelineDecisionLowHighMark,
                        PipelineDecision (..), runPipelineDecision, MkPipelineDecision)
import           Ouroboros.Network.Protocol.ChainSync.Type (ChainSync)
import           Ouroboros.Network.Protocol.LocalStateQuery.Client as StateQuery
import           Ouroboros.Network.Protocol.LocalStateQuery.Type (AcquireFailure)
import qualified Ouroboros.Network.Snocket as Snocket
import           Ouroboros.Network.Subscription (SubscriptionTrace)

import           Prelude (String)
import qualified Prelude

import qualified Shelley.Spec.Ledger.Genesis as Shelley

import qualified System.Metrics.Prometheus.Metric.Gauge as Gauge



data StateQueryTMVar m block result = StateQueryTMVar
  { sqvRequest :: StrictTMVar m (Point block, Query block result)
  , sqvResult :: StrictTMVar m (Either AcquireFailure result)
  }

localStateQueryHandler
    :: forall blk m pr result st . MonadIO m
    => Trace IO Text -> StateQueryTMVar m blk result
    -> Peer (LocalStateQuery blk (Query blk)) pr st m ()
localStateQueryHandler _tracer queryVar =
    loop
  where
    loop :: MonadIO m => Peer (LocalStateQuery blk (Query blk)) pr st m a
    loop = do
      request <- atomically $ lift (takeTMVar $ sqvRequest queryVar)
      response <- submitQuery request
      atomically $ lift (putTMVar (sqvResult queryVar) response)
      loop

submitQuery
    :: MonadIO m
    => (Point blk, Query blk result)
    -> Peer (LocalStateQuery blk (Query blk)) pr st m (Either AcquireFailure result)
submitQuery = panic "Cardano.DbSync.StateQuery.submitQuery"





{-

--TODO: change this query to be just a protocol client handler to be used with
-- connectToLocalNode. This would involve changing connectToLocalNode to be
-- able to return protocol handler results properly.

-- | Establish a connection to a node and execute a single query using the
-- local state query protocol.
--
queryNodeLocalState
    :: forall mode block result. (Typeable block, Typeable (ApplyTxErr block))
    => LocalNodeConnectInfo mode block -> (Point block, Query block result)
    -> IO (Either AcquireFailure result)
queryNodeLocalState connctInfo pointAndQuery = do
    resultVar <- newEmptyTMVarIO
    connectToLocalNode
        connctInfo
        nullLocalNodeClientProtocols
            { localStateQueryClient =
                Just (localStateQuerySingle resultVar pointAndQuery)
            }
    atomically (takeTMVar resultVar)
  where
    localStateQuerySingle
        :: TMVar (Either AcquireFailure result)
        -> (Point block, Query block result)
        -> LocalStateQueryClient block (Query block) IO ()
    localStateQuerySingle resultVar (point, query) =
      LocalStateQueryClient $ pure $
        SendMsgAcquire point $
          ClientStAcquiring
            { recvMsgAcquired =
                SendMsgQuery query $
                  ClientStQuerying
                    { recvMsgResult = \result -> do
                        --TODO: return the result via the SendMsgDone rather than
                        -- writing into an mvar
                        atomically $ putTMVar resultVar (Right result)
                        pure $ SendMsgRelease $ StateQuery.SendMsgDone ()
                    }
            , recvMsgFailure = \failure -> do
                --TODO: return the result via the SendMsgDone rather than
                -- writing into an mvar
                atomically $ putTMVar resultVar (Left failure)
                pure $ StateQuery.SendMsgDone ()
            }

-}
