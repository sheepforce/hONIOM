{-# LANGUAGE TemplateHaskell #-}

-- |
-- Module      : Spicy.JobDriver
-- Description : Combination of steps to full ONIOM jobs
-- Copyright   : Phillip Seeber, 2020
-- License     : GPL-3
-- Maintainer  : phillip.seeber@uni-jena.de
-- Stability   : experimental
-- Portability : POSIX, Windows
--
-- This module provides the main glue for fragment method logics.
module Spicy.JobDriver
  ( spicyExecMain,
  )
where

import Data.FileEmbed
import Data.List.Split
import qualified Data.Map as Map
import Optics hiding (view)
import RIO hiding
  ( view,
    (.~),
    (^.),
  )
import qualified RIO.HashMap as HashMap
import RIO.Process
import Spicy.Common
import Spicy.Data
import Spicy.InputFile
import Spicy.Molecule
import Spicy.ONIOM.AtomicDriver
import Spicy.ONIOM.Collector
import Spicy.ONIOM.Layout
import Spicy.RuntimeEnv
import Spicy.Wrapper
import Spicy.Wrapper.IPI.Pysisyphus
import qualified System.Path as Path

logSource :: LogSource
logSource = "JobDriver"

----------------------------------------------------------------------------------------------------

-- | The Spicy Logo as ASCII art.
jobDriverText :: Text
jobDriverText =
  decodeUtf8Lenient $(embedFile . Path.toString . Path.relFile $ "data/Fonts/JobDriver.txt")

----------------------------------------------------------------------------------------------------
spicyExecMain ::
  ( HasMolecule env,
    HasInputFile env,
    HasLogFunc env,
    HasWrapperConfigs env,
    HasProcessContext env,
    HasCalcSlot env
  ) =>
  RIO env ()
spicyExecMain = do
  -- Start the companion threads for i-PI, Pysis and the calculations.
  calcSlotThread <- async provideCalcSlot
  link calcSlotThread
  (pysisServer, pysisClient) <- providePysis

  -- Building an inital neighbourlist for large distances.
  logInfo "Constructing initial neighbour list for molecule ..."
  initNeighbourList

  -- Apply topology updates as given in the input file to the molecule.
  logInfo "Applying changes to the input topology ..."
  changeTopologyOfMolecule

  -- The molecule as loaded from the input file must be layouted to fit the current calculation
  -- type.
  logInfo "Preparing layout for a MC-ONIOMn calculation ..."
  layoutMoleculeForCalc

  -- Perform the specified tasks on the input file.
  tasks <- view $ inputFileL % #task
  forM_ tasks $ \t -> do
    case t of
      Energy -> multicentreOniomNDriver WTEnergy *> multicentreOniomNCollector WTEnergy
      Optimise Macro -> geomMacroDriver
      Optimise Micro -> undefined
      Frequency -> multicentreOniomNDriver WTHessian *> multicentreOniomNCollector WTHessian
      MD -> do
        logError "A MD run was requested but MD is not implemented yet."
        throwM $ SpicyIndirectionException "spicyExecMain" "MD is not implemented yet."

  -- LOG
  -- finalMol <- view moleculeL >>= atomically . readTVar
  -- logDebug . display . writeSpicy $ finalMol

  -- Kill the companion threads after we are done.
  cancel calcSlotThread
  wait pysisClient
  wait pysisServer

  -- LOG
  logInfo "Spicy execution finished. Wup Wup!"

----------------------------------------------------------------------------------------------------

-- | Construct an initial neighbour list with large distances for all atoms. Can be reduced to
-- smaller values efficiently.
initNeighbourList :: (HasMolecule env) => RIO env ()
initNeighbourList = do
  molT <- view moleculeL
  mol <- readTVarIO molT
  nL <- neighbourList 15 mol
  atomically . writeTVar molT $ mol & #neighbourlist .~ Map.singleton 15 nL

----------------------------------------------------------------------------------------------------

-- | Application of the topology updates, that were requested in the input file. The order of
-- application is:
--
--   1. Guess a new bond matrix if requested.
--   2. Remove bonds between pairs of atoms.
--   3. Add bonds between pairs of atoms.
changeTopologyOfMolecule ::
  (HasInputFile env, HasMolecule env, HasLogFunc env) => RIO env ()
changeTopologyOfMolecule = do
  -- Get the molecule to manipulate
  molT <- view moleculeL
  mol <- readTVarIO molT

  -- Get the input file information.
  inputFile <- view inputFileL

  case inputFile ^. #topology of
    Nothing -> return ()
    Just topoChanges -> do
      -- Resolve the defaults to final values.
      let covScalingFactor = fromMaybe defCovScaling $ topoChanges ^. #radiusScaling
          removalPairs = fromMaybe [] $ topoChanges ^. #bondsToRemove
          additionPairs = fromMaybe [] $ topoChanges ^. #bondsToAdd

      -- Show what will be done to the topology:
      logInfo $
        "  Guessing new bonds (scaling factor): "
          <> if topoChanges ^. #guessBonds
            then display covScalingFactor
            else "No"
      logInfo "  Removing bonds between atom pairs:"
      mapM_ (logInfo . ("    " <>) . utf8Show) $ chunksOf 5 removalPairs
      logInfo "  Adding bonds between atom pairs:"
      mapM_ (logInfo . ("    " <>) . utf8Show) $ chunksOf 5 additionPairs

      -- Apply changes to the topology
      let bondMatrixFromInput = mol ^. #bonds
      unless (HashMap.null bondMatrixFromInput) $
        logWarn
          "The input file format contains topology information such as bonds\
          \ but manipulations were requested anyway."

      -- Completely guess new bonds if requested.
      molNewBondsGuess <-
        if topoChanges ^. #guessBonds
          then do
            bondMatrix <- guessBondMatrix (Just covScalingFactor) mol
            return $ mol & #bonds .~ bondMatrix
          else return mol

      -- Remove all bonds between atom pairs requested.
      molNewBondsRemoved <-
        foldl'
          ( \molAcc' atomPair -> do
              molAcc <- molAcc'
              molAccNew <- changeBond Remove molAcc atomPair
              return molAccNew
          )
          (return molNewBondsGuess)
          removalPairs

      -- Add all bonds between atom pairs requested.
      molNewBondsAdded <-
        foldl'
          ( \molAcc' atomPair -> do
              molAcc <- molAcc'
              molAccNew <- changeBond Add molAcc atomPair
              return molAccNew
          )
          (return molNewBondsRemoved)
          additionPairs

      -- The molecule after all changes to the topology have been applied.
      atomically . writeTVar molT $ molNewBondsAdded

----------------------------------------------------------------------------------------------------

-- | Perform transformation of the molecule data structure as obtained from the input to match the
-- requirements for the requested calculation type.
layoutMoleculeForCalc ::
  (HasInputFile env, HasMolecule env) => RIO env ()
layoutMoleculeForCalc = do
  inputFile <- view inputFileL
  case inputFile ^. #model of
    ONIOMn {} -> mcOniomNLayout
