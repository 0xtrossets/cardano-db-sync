{-# LANGUAGE StrictData #-}
module Cardano.Db.Tool.Validate.TotalSupply
  ( validateTotalSupplyDecreasing
  ) where

import           Cardano.Db.Tool.Validate.Util

import           Data.Word (Word64)

import           Cardano.Db

import           System.Random (randomRIO)


-- | Validate that the total supply is decreasing.
-- This is only true for the Byron error where transaction fees are burnt.
validateTotalSupplyDecreasing :: IO ()
validateTotalSupplyDecreasing = do
    test <- genTestParameters

    putStrF $ "Total supply + fees + deposit - withdrawals at block " ++ show (testBlockNo test)
            ++ " is same as genesis supply: "

    accounting <- queryInitialSupply (testBlockNo test)

    let total = accSupply accounting + accFees accounting - accWithdrawals accounting

    if genesisSupply test == total
      then putStrLn $ greenText "ok"
      else error $ redText (show (genesisSupply test) ++ " /= " ++ show total)

-- -----------------------------------------------------------------------------

data Accounting = Accounting
  { accFees :: Ada
  , accWithdrawals :: Ada
  , accSupply :: Ada
  }

data TestParams = TestParams
  { testBlockNo :: Word64
  , genesisSupply :: Ada
  }

genTestParameters :: IO TestParams
genTestParameters = do
  mlatest <- runDbNoLogging queryLatestBlockNo
  case mlatest of
    Nothing -> error "Cardano.Db.Tool.Validation: Empty database"
    Just latest ->
      TestParams
          <$> randomRIO (1, latest - 1)
          <*> runDbNoLogging queryGenesisSupply


queryInitialSupply :: Word64 -> IO Accounting
queryInitialSupply blkNo =
  -- Run all queries in a single transaction.
  runDbNoLogging $
    Accounting
      <$> queryFeesUpToBlockNo blkNo
      <*> queryWithdrawalsUpToBlockNo blkNo
      <*> fmap2 utxoSetSum queryUtxoAtBlockNo blkNo
