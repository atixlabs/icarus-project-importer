{-# LANGUAGE Arrows #-}

module Pos.BlockchainImporter.Tables.UtxosTable
  ( -- * Data types
    UtxoRecord (..)
    -- * Getters
  , getUtxos
    -- * Manipulation
  , applyModifierToUtxos
    -- * Recovery (use carefully!)
  , clearUtxos
  ) where

import           Universum

import qualified Control.Arrow as A
import           Data.Maybe (catMaybes)
import           Data.Profunctor.Product.TH (makeAdaptorAndInstance)
import qualified Database.PostgreSQL.Simple as PGS
import           Opaleye
import           Opaleye.RunSelect

import           Pos.BlockchainImporter.Tables.Utils
import           Pos.Core.Txp (TxIn (..), TxOut (..), TxOutAux (..))
import           Pos.Txp.Toil.Types (UtxoModifier)
import qualified Pos.Util.Modifier as MM

data UtxoRecord = UtxoRecord
    { utxoInput  :: !TxIn
    , utxoOutput :: !TxOutAux
    }

data UtxoRowPoly a b c d e = UtxoRow  { urUtxoId   :: a
                                      , urTxHash   :: b
                                      , urTxIndex  :: c
                                      , urReceiver :: d
                                      , urAmount   :: e
                                      } deriving (Show)

type UtxoRowPGW = UtxoRowPoly (Column PGText) (Column PGText) (Column PGInt4) (Column PGText) (Column PGInt8)
type UtxoRowPGR = UtxoRowPoly (Column PGText) (Column PGText) (Column PGInt4) (Column PGText) (Column PGInt8)

$(makeAdaptorAndInstance "pUtxos" ''UtxoRowPoly)

utxosTable :: Table UtxoRowPGW UtxoRowPGR
utxosTable = Table "utxos" (pUtxos UtxoRow  { urUtxoId = required "utxo_id"
                                            , urTxHash = required "tx_hash"
                                            , urTxIndex = required "tx_index"
                                            , urReceiver = required "receiver"
                                            , urAmount = required "amount"
                                            })

txId :: TxIn -> String
txId (TxInUtxo txHash txIndex) = hashToString txHash ++ show txIndex
txId _                         = ""

toRecord :: TxIn -> TxOutAux -> Maybe UtxoRowPGW
toRecord txIn@(TxInUtxo txHash txIndex) (TxOutAux (TxOut receiver value)) = Just $ row
  where sHash     = hashToString txHash
        iIndex    = fromIntegral txIndex
        sAddress  = addressToString receiver
        iAmount   = coinToInt64 value
        row       = UtxoRow (pgString $ txId txIn)
                            (pgString sHash) (pgInt4 iIndex)
                            (pgString sAddress) (pgInt8 iAmount)
toRecord _ _ = Nothing

-- | Applies a UtxoModifier to the UTxOs in the table
applyModifierToUtxos :: UtxoModifier -> PGS.Connection -> IO ()
applyModifierToUtxos modifier conn = do
  let toInsert = catMaybes $ (uncurry toRecord) <$> MM.insertions modifier
      toDelete = (pgString . txId) <$> MM.deletions modifier
  void $ runUpsert_ conn utxosTable ["utxo_id"] [] toInsert
  void $ runDelete_ conn $
                    Delete utxosTable (\(UtxoRow sId _ _ _ _) -> in_ toDelete sId) rCount

-- | Returns the utxo stored in the table
getUtxos :: PGS.Connection -> IO [UtxoRecord]
getUtxos conn = do
  utxos :: [(Text, Int, Text, Int64)] <- runSelect conn utxosQuery
  pure $ catMaybes $ (flip map) utxos $ \(inHash, inIndex, outReceiver, outAmount) -> do
    input <- toTxIn inHash inIndex
    output <- toTxOutAux outReceiver outAmount
    pure $ UtxoRecord input output
  where utxosQuery = proc () -> do
          UtxoRow _ inHash inIndex outReceiver outAmount <- (selectTable utxosTable) -< ()
          A.returnA -< (inHash, inIndex, outReceiver, outAmount)

-- | Delete all utxos from table
clearUtxos :: PGS.Connection -> IO ()
clearUtxos conn = void $ runDelete_ conn $
                                    Delete utxosTable (const $ pgBool True) rCount
