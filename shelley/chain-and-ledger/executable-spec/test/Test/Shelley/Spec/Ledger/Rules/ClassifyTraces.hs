{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TypeApplications #-}

module Test.Shelley.Spec.Ledger.Rules.ClassifyTraces
  ( onlyValidLedgerSignalsAreGenerated
  , onlyValidChainSignalsAreGenerated
  , relevantCasesAreCovered
  , propAbstractSizeBoundsBytes
  , propAbstractSizeNotTooBig)
  where

import qualified Data.ByteString as BS
import           Data.Foldable (toList)
import qualified Data.Map.Strict as Map
import           Data.Sequence.Strict (StrictSeq)
import           Test.QuickCheck (Property, checkCoverage, conjoin, cover, property, withMaxSuccess)
import qualified Test.QuickCheck.Gen
import           Cardano.Binary (serialize')
import           Cardano.Slotting.Slot (EpochSize (..))
import           Control.State.Transition.Trace (TraceOrder (OldestFirst), traceLength,
                     traceSignals)
import           Control.State.Transition.Trace.Generator.QuickCheck (classifyTraceLength,
                     forAllTraceFromInitState, onlyValidSignalsAreGeneratedFromInitState)
import           Shelley.Spec.Ledger.BaseTypes (Globals (epochInfo))
import           Shelley.Spec.Ledger.BlockChain (pattern Block, pattern TxSeq, bhbody,
                     bheaderSlotNo)
import           Shelley.Spec.Ledger.Delegation.Certificates (isDeRegKey, isDelegation,
                     isGenesisDelegation, isInstantaneousRewards, isRegKey, isRegPool,
                     isRetirePool)
import           Shelley.Spec.Ledger.LedgerState (txsize)
import           Shelley.Spec.Ledger.PParams (PParamsUpdate, pattern ProposedPPUpdates,
                     pattern Update)
import           Shelley.Spec.Ledger.Slot (SlotNo (..), epochInfoSize)
import           Shelley.Spec.Ledger.Tx (_body)
import           Shelley.Spec.Ledger.TxData (pattern AddrBase, pattern DCertDeleg, pattern DeRegKey,
                     pattern Delegate, pattern Delegation, pattern RegKey, pattern ScriptHashObj,
                     pattern TxOut, Wdrl (..), _certs, _outputs, _txUpdate, _wdrls)

import           Test.Shelley.Spec.Ledger.Generator.Core (GenEnv(..))
import           Test.Shelley.Spec.Ledger.ConcreteCryptoTypes (ChainState, Block, CHAIN, DCert, LEDGER, Tx,
                     TxOut, DPState, UTxOState)
import           Test.Shelley.Spec.Ledger.Generator.Constants (Constants(..))
import           Test.Shelley.Spec.Ledger.Generator.Presets (genEnv)
import           Test.Shelley.Spec.Ledger.Generator.Trace.Chain (mkGenesisChainState)
import           Test.Shelley.Spec.Ledger.Generator.Trace.Ledger (mkGenesisLedgerState)
import           Test.Shelley.Spec.Ledger.Utils
import qualified Control.State.Transition.Extended



genesisChainState ::
  Maybe
    ( Control.State.Transition.Extended.IRC CHAIN ->
      Test.QuickCheck.Gen.Gen
        ( Either
            a
            Test.Shelley.Spec.Ledger.ConcreteCryptoTypes.ChainState
        )
    )
genesisChainState = Just $ mkGenesisChainState (geConstants genEnv)

genesisLedgerState
  :: Maybe
      (Control.State.Transition.Extended.IRC LEDGER
        -> Test.QuickCheck.Gen.Gen
            (Either
                a
                (Test.Shelley.Spec.Ledger.ConcreteCryptoTypes.UTxOState,
                Test.Shelley.Spec.Ledger.ConcreteCryptoTypes.DPState)))
genesisLedgerState = Just $ mkGenesisLedgerState (geConstants genEnv)

relevantCasesAreCovered :: Property
relevantCasesAreCovered = withMaxSuccess 200 . property $ do
  let tl = 100
      GenEnv _ c@(Constants{maxCertsPerTx}) = genEnv
  forAllTraceFromInitState @CHAIN testGlobals tl genEnv genesisChainState $ \tr -> do
    let blockTxs (Block _ (TxSeq txSeq)) = toList txSeq
        bs = traceSignals OldestFirst tr
        txs = concat (blockTxs <$> bs)
        certs_ = allCerts txs

    checkCoverage $ conjoin [
       classifyTraceLength tl 5 tr

     , cover_ 60
              (traceLength tr <= 3 * length certs_)
              "there is at least 1 certificate for every 3 transactions"

     , cover_ 60
              (traceLength tr <= 10 * length (filter isRegKey certs_))
              "there is at least 1 RegKey certificate for every 10 transactions"

     , cover_ 60
              (traceLength tr <= 10 * length (filter isDeRegKey certs_))
              "there is at least 1 DeRegKey certificate for every 10 transactions"

     , cover_ 60
              (traceLength tr <= 10 * length (filter isDelegation certs_))
              "there is at least 1 Delegation certificate for every 10 transactions"

     , cover_ 60
              (traceLength tr <= 20 * length (filter isGenesisDelegation certs_))
              "there is at least 1 Genesis Delegation certificate for every 20 transactions"

     , cover_ 60
              (traceLength tr <= 10 * length (filter isRegPool certs_))
              "there is at least 1 RegPool certificate for every 10 transactions"

     , cover_ 60
              (traceLength tr <= 10 * length (filter isRetirePool certs_))
              "there is at least 1 RetirePool certificate for every 10 transactions"

     , cover_ 60
              (traceLength tr <= 30 * length (filter isInstantaneousRewards certs_))
              "there is at least 1 MIR certificate for every 30 transactions"

     , cover_ 60
              (0.6 >= noCertsRatio (certsByTx txs))
              "at most 60% of transactions have no certificates"

     , cover_ 60
              (0.1 <= maxCertsRatio c (certsByTx txs))
              ("at least 10% of transactions have " <> (show maxCertsPerTx) <> " certificates")

     , cover_ 20
              (0.1 <= txScriptOutputsRatio (map (_outputs . _body) txs))
              "at least 10% of transactions have script TxOuts"
     , cover_ 60
              (0.1 <= scriptCredentialCertsRatio certs_)
              "at least 10% of `DCertDeleg` certificates have script credentials"
     , cover_ 60
              (0.1 <= withdrawalRatio txs)
              "at least 10% of transactions have a reward withdrawal"

     , cover_ 60
              (0.98 >= noPPUpdateRatio (ppUpdatesByTx txs))
              "at least 2% of transactions have non-trivial protocol param updates"

     , cover_ 60
              (2 <= epochBoundariesInTrace bs)
              "at least 2 epoch changes in trace"

     , cover_ 20
              (5 <= epochBoundariesInTrace bs)
              "at least 5 epoch changes in trace"
     ]
    where
      cover_ pc b s = cover pc b s (property ())


-- | Ratio of certificates with script credentials to the number of certificates
-- that could have script credentials.
scriptCredentialCertsRatio :: [DCert] -> Double
scriptCredentialCertsRatio certs =
  ratioInt haveScriptCerts couldhaveScriptCerts
  where haveScriptCerts =
          (length $ filter
            (\case
                DCertDeleg (RegKey (ScriptHashObj _))                  -> True
                DCertDeleg (DeRegKey (ScriptHashObj _))                -> True
                DCertDeleg (Delegate (Delegation (ScriptHashObj _) _)) -> True
                _                                                      -> False)
            certs)
        couldhaveScriptCerts =
          length $ filter (\case
                               DCertDeleg _ -> True
                               _            -> False) certs

-- | Extract the certificates from the transactions
certsByTx :: [Tx] -> [[DCert]]
certsByTx txs = toList . _certs . _body <$> txs

-- | Flattended list of DCerts for the given transactions
allCerts :: [Tx] -> [DCert]
allCerts = concat . certsByTx

-- | Ratio of the number of empty certificate groups and the number of groups
noCertsRatio :: [[DCert]] -> Double
noCertsRatio = lenRatio (filter null)

-- | Ratio of the number of certificate groups of max size and the number of groups
maxCertsRatio :: Constants -> [[DCert]] -> Double
maxCertsRatio Constants{maxCertsPerTx} = lenRatio (filter ((== maxCertsPerTx) . fromIntegral . length))

-- | Extract non-trivial protocol param  updates from the given transactions
ppUpdatesByTx :: [Tx] -> [[PParamsUpdate]]
ppUpdatesByTx txs = ppUpdates . _txUpdate . _body <$> txs
  where
    ppUpdates Nothing = mempty
    ppUpdates (Just (Update (ProposedPPUpdates ppUpd) _)) = Map.elems ppUpd

-- | Ratio of the number of empty PParamsUpdate to Updates
noPPUpdateRatio :: [[PParamsUpdate]] -> Double
noPPUpdateRatio = lenRatio (filter null)

ratioInt :: Int -> Int -> Double
ratioInt x y
  = fromIntegral x / fromIntegral y

-- | Transaction has script locked TxOuts
txScriptOutputsRatio :: [StrictSeq TxOut] -> Double
txScriptOutputsRatio txoutsList =
  ratioInt
   (sum (map countScriptOuts txoutsList))
   (sum (map length txoutsList))
  where countScriptOuts txouts =
          sum $ fmap (\case
                        TxOut (AddrBase (ScriptHashObj _) _) _ -> 1
                        _ -> 0) txouts

-- | Transaction has a reward withdrawal
withdrawalRatio :: [Tx] -> Double
withdrawalRatio = lenRatio (filter $ not . null . unWdrl . _wdrls . _body)

-- | Transforms the list and returns the ratio of lengths of
-- the transformed and original lists.
lenRatio :: ([a] -> [b]) -> [a] -> Double
lenRatio f xs
  = ratioInt (length (f xs))
             (length xs)

onlyValidLedgerSignalsAreGenerated :: Property
onlyValidLedgerSignalsAreGenerated = withMaxSuccess 200 $
    onlyValidSignalsAreGeneratedFromInitState @LEDGER testGlobals 100 genEnv genesisLedgerState

-- | Check that the abstract transaction size function
-- actually bounds the number of bytes in the serialized transaction.
propAbstractSizeBoundsBytes :: Property
propAbstractSizeBoundsBytes = property $ do
  let tl = 100
      numBytes = toInteger . BS.length . serialize'
  forAllTraceFromInitState @LEDGER testGlobals tl genEnv genesisLedgerState $ \tr -> do
    let txs :: [Tx]
        txs = traceSignals OldestFirst tr
    all (\tx -> txsize tx >= numBytes tx) txs

-- | Check that the abstract transaction size function
-- is not off by an acceptable order of magnitude.
propAbstractSizeNotTooBig :: Property
propAbstractSizeNotTooBig = property $ do
  let tl = 100
      -- The below acceptable order of magnitude may not actually be large enough.
      -- For small transactions, estimating the size of an encoded uint as 5
      -- may mean that our size is more like five times too big.
      -- It will be interesting to see the test fail with
      -- an acceptableMagnitude of three, though.
      acceptableMagnitude = (3 :: Integer)
      numBytes = toInteger . BS.length . serialize'
      notTooBig txb = txsize txb <= acceptableMagnitude * numBytes txb
  forAllTraceFromInitState @LEDGER testGlobals tl genEnv genesisLedgerState $ \tr -> do
    let txs :: [Tx]
        txs = traceSignals OldestFirst tr
    all notTooBig txs

onlyValidChainSignalsAreGenerated :: Property
onlyValidChainSignalsAreGenerated = withMaxSuccess 100 $
  onlyValidSignalsAreGeneratedFromInitState @CHAIN testGlobals 100 genEnv genesisChainState

epochBoundariesInTrace :: [Block] -> Int
epochBoundariesInTrace bs
  = length $
      filter atEpochBoundary (blockSlot <$> bs)
  where
    EpochSize slotsPerEpoch = runShelleyBase $ (epochInfoSize . epochInfo) testGlobals undefined

    blockSlot (Block bh _) = (bheaderSlotNo . bhbody) bh
    atEpochBoundary (SlotNo s) = s `rem` slotsPerEpoch == 0
