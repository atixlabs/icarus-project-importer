-- | Arbitrary instances for BlockchainImporter types.

module Pos.Arbitrary.BlockchainImporter () where

import           Test.QuickCheck (Arbitrary (..))
import           Test.QuickCheck.Arbitrary.Generic (genericArbitrary, genericShrink)

import           Pos.Core.Common (HeaderHash)
import           Pos.BlockchainImporter.Core.Types (TxExtra (..))
import           Pos.Txp ()

instance Arbitrary HeaderHash => Arbitrary TxExtra where
    arbitrary = genericArbitrary
    shrink = genericShrink
