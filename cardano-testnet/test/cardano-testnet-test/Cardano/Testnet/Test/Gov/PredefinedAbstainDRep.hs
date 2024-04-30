{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Cardano.Testnet.Test.Gov.PredefinedAbstainDRep
  ( hprop_check_predefined_abstain_drep
  ) where

import           Cardano.Api as Api
import           Cardano.Api.Error (displayError)
import           Cardano.Api.IO.Base (Socket)

import           Cardano.Testnet

import           Prelude

import           Control.Monad (void)
import           Control.Monad.Catch (MonadCatch)
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Lens as AL
import           Data.ByteString.Lazy.Char8 (pack)
import           Data.String (fromString)
import qualified Data.Text as Text
import           Data.Word (Word32)
import           GHC.Stack (callStack)
import           Lens.Micro ((^?))
import           System.FilePath ((</>))

import           Testnet.Components.Query (EpochStateView, findLargestUtxoForPaymentKey,
                   getCurrentEpochNo, getEpochStateView, getMinDRepDeposit)
import           Testnet.Defaults (defaultDRepKeyPair, defaultDelegatorStakeKeyPair)
import           Testnet.Process.Cli.DRep (createCertificatePublicationTxBody, createVotingTxBody,
                   generateVoteFiles)
import qualified Testnet.Process.Cli.Keys as P
import           Testnet.Process.Cli.Transaction (retrieveTransactionId, signTx, submitTx)
import qualified Testnet.Process.Run as H
import qualified Testnet.Property.Util as H
import           Testnet.Runtime
import           Testnet.Types (KeyPair (..),
                   PaymentKeyInfo (paymentKeyInfoAddr, paymentKeyInfoPair), PoolNode (..),
                   SomeKeyPair (SomeKeyPair), StakingKey, TestnetRuntime (..), nodeSocketPath)

import           Hedgehog
import qualified Hedgehog.Extras as H

-- | This test creates a default testnet with three DReps and one stake holder delegated to each.
-- We then do a proposal for an arbitrary parameter change (in this case to the
-- @desiredNumberOfPools@ parameter) to check that it fails, when the first DRep votes "yes" and the
-- last two vote "no". Later we chack that if we change the stake holders under the DReps that vote
-- "no" to delegate to the automate "always abstain" DRep, the same kind of proposal passes.
-- 
-- This test is meant to ensure that delegating to "always abstain" has the desired effect of
-- counting as abstaining for the stake delegated.
--
-- Execute me with:
-- @DISABLE_RETRIES=1 cabal test cardano-testnet-test --test-options '-p "/Predefined Abstain DRep/"'@
hprop_check_predefined_abstain_drep :: Property
hprop_check_predefined_abstain_drep = H.integrationWorkspace "test-activity" $ \tempAbsBasePath' -> do
  -- Start a local test net
  conf@Conf { tempAbsPath } <- mkConf tempAbsBasePath'
  let tempAbsPath' = unTmpAbsPath tempAbsPath
      tempBaseAbsPath = makeTmpBaseAbsPath tempAbsPath
  work <- H.createDirectoryIfMissing $ tempAbsPath' </> "work"

  -- Create default testnet with 3 DReps and 3 stake holders delegated, one to each DRep.
  let ceo = ConwayEraOnwardsConway
      sbe = conwayEraOnwardsToShelleyBasedEra ceo
      era = toCardanoEra sbe
      cEra = AnyCardanoEra era
      fastTestnetOptions = cardanoDefaultTestnetOptions
        { cardanoEpochLength = 100
        , cardanoNodeEra = cEra
        , cardanoNumDReps = 3
        }

  testnetRuntime@TestnetRuntime
    { testnetMagic
    , poolNodes
    , wallets=wallet0:wallet1:wallet2:_
    , configurationFile
    }
    <- cardanoTestnetDefault fastTestnetOptions conf

  PoolNode{poolRuntime} <- H.headM poolNodes
  poolSprocket1 <- H.noteShow $ nodeSprocket poolRuntime
  execConfig <- H.mkExecConfig tempBaseAbsPath poolSprocket1 testnetMagic
  let socketPath = nodeSocketPath poolRuntime

  epochStateView <- getEpochStateView configurationFile socketPath

  startLedgerNewEpochStateLogging testnetRuntime tempAbsPath'

  H.note_ $ "Sprocket: " <> show poolSprocket1
  H.note_ $ "Abs path: " <> tempAbsBasePath'
  H.note_ $ "Socketpath: " <> unFile socketPath
  H.note_ $ "Foldblocks config file: " <> unFile configurationFile

  gov <- H.createDirectoryIfMissing $ work </> "governance"

  initialDesiredNumberOfPools <- getDesiredPoolNumberValue execConfig

  let newNumberOfDesiredPools = fromIntegral (initialDesiredNumberOfPools + 1)

  -- Do some proposal and vote yes with the first DRep only
  -- and assert that proposal does NOT pass.
  void $ desiredPoolNumberProposalTest execConfig epochStateView configurationFile socketPath ceo gov "firstProposal"
                                       wallet0 Nothing [(1, "yes")] newNumberOfDesiredPools initialDesiredNumberOfPools 2

  -- Take the last two stake delegators and delegate them to "Abstain".
  delegateToAlwaysAbstain execConfig epochStateView configurationFile socketPath sbe gov "delegateToAbstain1"
                          wallet1 (defaultDelegatorStakeKeyPair 2)
  delegateToAlwaysAbstain execConfig epochStateView configurationFile socketPath sbe gov "delegateToAbstain2"
                          wallet2 (defaultDelegatorStakeKeyPair 3)

  -- Do some other proposal and vote yes with first DRep only
  -- and assert the new proposal passes now.
  let newNumberOfDesiredPools2 = fromIntegral (newNumberOfDesiredPools + 1)
  void $ desiredPoolNumberProposalTest execConfig epochStateView configurationFile socketPath ceo gov "secondProposal"
                                       wallet0 Nothing [(1, "yes")] newNumberOfDesiredPools2 newNumberOfDesiredPools2 2

delegateToAlwaysAbstain
  :: (MonadTest m, MonadIO m, H.MonadAssertion m, MonadCatch m)
  => H.ExecConfig
  -> EpochStateView
  -> NodeConfigFile 'In
  -> File Socket 'InOut
  -> ShelleyBasedEra ConwayEra
  -> FilePath
  -> String
  -> PaymentKeyInfo
  -> KeyPair StakingKey
  -> m ()
delegateToAlwaysAbstain execConfig epochStateView configurationFile socketPath sbe work prefix
                        payingWallet skeyPair@(KeyPair vKeyFile _sKeyFile) = do

  let era = toCardanoEra sbe
      cEra = AnyCardanoEra era

  baseDir <- H.createDirectoryIfMissing $ work </> prefix

  -- Create vote delegation certificate
  let voteDelegationCertificatePath = baseDir </> "delegation-certificate.delegcert"
  void $ H.execCli' execConfig
    [ "conway", "stake-address", "vote-delegation-certificate"
    , "--always-abstain"
    , "--stake-verification-key-file", unFile vKeyFile
    , "--out-file", voteDelegationCertificatePath
    ]

  -- Compose transaction to publish delegation certificate
  repRegTxBody1 <- createCertificatePublicationTxBody execConfig epochStateView sbe baseDir "del-cert-txbody"
                                                      (File voteDelegationCertificatePath) payingWallet

  -- Sign transaction
  repRegSignedRegTx1 <- signTx execConfig cEra baseDir "signed-reg-tx"
                               repRegTxBody1 [ SomeKeyPair (paymentKeyInfoPair payingWallet)
                                             , SomeKeyPair skeyPair]

  -- Submit transaction
  submitTx execConfig cEra repRegSignedRegTx1

  -- Wait two epochs
  (EpochNo epochAfterProp) <- getCurrentEpochNo epochStateView
  void $ waitUntilEpoch configurationFile socketPath (EpochNo (epochAfterProp + 2))

desiredPoolNumberProposalTest
  :: (MonadTest m, MonadIO m, H.MonadAssertion m, MonadCatch m, Foldable t)
  => H.ExecConfig
  -> EpochStateView
  -> NodeConfigFile 'In
  -> File Socket 'InOut
  -> ConwayEraOnwards ConwayEra
  -> FilePath
  -> FilePath
  -> PaymentKeyInfo
  -> Maybe (String, Word32)
  -> t (Int, String)
  -> Integer
  -> Integer
  -> Integer
  -> m (String, Word32)
desiredPoolNumberProposalTest execConfig epochStateView configurationFile socketPath ceo work prefix
                              wallet previousProposalInfo votes change expected epochsToWait = do
  let sbe = conwayEraOnwardsToShelleyBasedEra ceo

  baseDir <- H.createDirectoryIfMissing $ work </> prefix

  let propVotes :: [(String, Int)]
      propVotes = zip (concatMap (uncurry replicate) votes) [1..]
  annotateShow propVotes

  thisProposal@(governanceActionTxId, governanceActionIndex) <-
    makeDesiredPoolNumberChangeProposal execConfig epochStateView configurationFile socketPath
                                            ceo baseDir "proposal" previousProposalInfo (fromIntegral change) wallet

  voteChangeProposal execConfig epochStateView sbe baseDir "vote"
                     governanceActionTxId governanceActionIndex propVotes wallet

  (EpochNo epochAfterProp) <- getCurrentEpochNo epochStateView
  H.note_ $ "Epoch after \"" <> prefix <> "\" prop: " <> show epochAfterProp

  void $ waitUntilEpoch configurationFile socketPath (EpochNo (epochAfterProp + fromIntegral epochsToWait))
  desiredPoolNumberAfterProp <- getDesiredPoolNumberValue execConfig

  desiredPoolNumberAfterProp === expected

  return thisProposal

makeDesiredPoolNumberChangeProposal
  :: (H.MonadAssertion m, MonadTest m, MonadCatch m, MonadIO m)
  => H.ExecConfig
  -> EpochStateView
  -> NodeConfigFile 'In
  -> SocketPath
  -> ConwayEraOnwards ConwayEra
  -> FilePath
  -> String
  -> Maybe (String, Word32)
  -> Word32
  -> PaymentKeyInfo
  -> m (String, Word32)
makeDesiredPoolNumberChangeProposal execConfig epochStateView configurationFile socketPath
                                    ceo work prefix prevGovActionInfo desiredPoolNumber wallet = do

  let sbe = conwayEraOnwardsToShelleyBasedEra ceo
      era = toCardanoEra sbe
      cEra = AnyCardanoEra era

  baseDir <- H.createDirectoryIfMissing $ work </> prefix

  let stakeVkeyFp = baseDir </> "stake.vkey"
      stakeSKeyFp = baseDir </> "stake.skey"

  P.cliStakeAddressKeyGen
    $ KeyPair { verificationKey = File stakeVkeyFp
              , signingKey = File stakeSKeyFp
              }

  proposalAnchorFile <- H.note $ baseDir </> "sample-proposal-anchor"
  H.writeFile proposalAnchorFile "dummy anchor data"

  proposalAnchorDataHash <- H.execCli' execConfig
    [ "conway", "governance"
    , "hash", "anchor-data", "--file-text", proposalAnchorFile
    ]

  minDRepDeposit <- getMinDRepDeposit epochStateView ceo

  proposalFile <- H.note $ baseDir </> "sample-proposal-file"

  void $ H.execCli' execConfig $
    [ "conway", "governance", "action", "create-protocol-parameters-update"
    , "--testnet"
    , "--governance-action-deposit", show @Integer minDRepDeposit
    , "--deposit-return-stake-verification-key-file", stakeVkeyFp
    ] ++ concatMap (\(prevGovernanceActionTxId, prevGovernanceActionIndex) ->
                      [ "--prev-governance-action-tx-id", prevGovernanceActionTxId
                      , "--prev-governance-action-index", show prevGovernanceActionIndex
                      ]) prevGovActionInfo ++
    [ "--number-of-pools", show desiredPoolNumber
    , "--anchor-url", "https://tinyurl.com/3wrwb2as"
    , "--anchor-data-hash", proposalAnchorDataHash
    , "--out-file", proposalFile
    ]

  proposalBody <- H.note $ baseDir </> "tx.body"
  txIn <- findLargestUtxoForPaymentKey epochStateView sbe wallet

  void $ H.execCli' execConfig
    [ "conway", "transaction", "build"
    , "--change-address", Text.unpack $ paymentKeyInfoAddr wallet
    , "--tx-in", Text.unpack $ renderTxIn txIn
    , "--proposal-file", proposalFile
    , "--out-file", proposalBody
    ]

  signedProposalTx <- signTx execConfig cEra baseDir "signed-proposal"
                             (File proposalBody) [SomeKeyPair $ paymentKeyInfoPair wallet]

  submitTx execConfig cEra signedProposalTx

  governanceActionTxId <- retrieveTransactionId execConfig signedProposalTx

  !propSubmittedResult <- findCondition (maybeExtractGovernanceActionIndex (fromString governanceActionTxId))
                                        configurationFile
                                        socketPath
                                        (EpochNo 30)

  governanceActionIndex <- case propSubmittedResult of
                             Left e ->
                               H.failMessage callStack
                                 $ "findCondition failed with: " <> displayError e
                             Right Nothing ->
                               H.failMessage callStack "Couldn't find proposal."
                             Right (Just a) -> return a

  return (governanceActionTxId, governanceActionIndex)

voteChangeProposal :: (MonadTest m, MonadIO m, MonadCatch m, H.MonadAssertion m)
  => H.ExecConfig
  -> EpochStateView
  -> ShelleyBasedEra ConwayEra
  -> FilePath
  -> FilePath
  -> String
  -> Word32
  -> [([Char], Int)]
  -> PaymentKeyInfo
  -> m ()
voteChangeProposal execConfig epochStateView sbe work prefix governanceActionTxId governanceActionIndex votes wallet = do
  baseDir <- H.createDirectoryIfMissing $ work </> prefix

  let era = toCardanoEra sbe
      cEra = AnyCardanoEra era

  voteFiles <- generateVoteFiles execConfig baseDir "vote-files"
                                 governanceActionTxId governanceActionIndex
                                 [(defaultDRepKeyPair idx, vote) | (vote, idx) <- votes]

  voteTxBodyFp <- createVotingTxBody execConfig epochStateView sbe baseDir "vote-tx-body"
                                     voteFiles wallet

  voteTxFp <- signTx execConfig cEra baseDir "signed-vote-tx" voteTxBodyFp
                     (SomeKeyPair (paymentKeyInfoPair wallet):[SomeKeyPair $ defaultDRepKeyPair n | (_, n) <- votes])
  submitTx execConfig cEra voteTxFp

-- | Obtains the @desiredPoolNumberValue@ from the protocol parameters.
-- The @desiredPoolNumberValue@ or (@k@ in the spec) is the protocol parameter
-- that defines what is the optimal number of SPOs. It is a tradeoff between
-- decentralization and efficiency and the spec suggest it should be between 100 an 1000.
-- Changing this parameter will inderectly affect how easy it is to saturate a pool in order to
-- incentivize that the number of SPOs states close to the parameter value.
getDesiredPoolNumberValue :: (MonadTest m, MonadCatch m, MonadIO m) => H.ExecConfig -> m Integer
getDesiredPoolNumberValue execConfig = do
  govStateString <- H.execCli' execConfig
    [ "conway", "query", "gov-state"
    , "--volatile-tip"
    ]

  govStateJSON <- H.nothingFail (Aeson.decode (pack govStateString) :: Maybe Aeson.Value)
  let mTargetPoolNum :: Maybe Integer
      mTargetPoolNum = govStateJSON
                             ^? AL.key "currentPParams"
                              . AL.key "stakePoolTargetNum"
                              . AL._Integer
  evalMaybe mTargetPoolNum
