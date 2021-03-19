-- |
-- Module      : Spicy.ONIOM.AtomicDriver
-- Description : Preparation, running an analysis of ONIOM jobs on layouted systems
-- Copyright   : Phillip Seeber, 2021
-- License     : GPL-3
-- Maintainer  : phillip.seeber@uni-jena.de
-- Stability   : experimental
-- Portability : POSIX, Windows
--
-- The driver method for ONIOM applications. This modules uses the layouted molecules and performs an
-- atomic task with them (energy, gradient, hessian or property calculation).
--
-- - Updates all calculation contexts to perform the correct task
-- - Call wrappers to perform the calculations specified, get their output and update all 'CalcOutput's
-- - Combine all data from 'CalcOutput' to a final ONIOM result, according to the task.
module Spicy.ONIOM.AtomicDriver
  ( oniomCalcDriver,
    multicentreOniomNDriver,
    geomMacroDriver,
  )
where

import Data.Default
import qualified Data.IntMap as IntMap
import Data.Massiv.Array as Massiv hiding (forM_, loop)
import Data.Massiv.Array.Manifest.Vector as Massiv
import Optics hiding (Empty, view)
import RIO hiding
  ( view,
    (%~),
    (.~),
    (^.),
    (^..),
    (^?),
  )
import qualified RIO.HashSet as HashSet
import qualified RIO.Map as Map
import RIO.Process
import RIO.Seq (Seq (..))
import qualified RIO.Vector.Storable as VectorS
import Spicy.Common
import Spicy.Data
import Spicy.InputFile
import Spicy.Molecule
import Spicy.ONIOM.Collector
import Spicy.Outputter as Out
import Spicy.RuntimeEnv
import Spicy.Wrapper.IPI.Protocol
import Spicy.Wrapper.IPI.Pysisyphus
import Spicy.Wrapper.IPI.Types

-- | A primitive driver, that executes a given calculation on a given layer. No results will be
-- transered from the calculation output to the actual fields of the molecule.
oniomCalcDriver ::
  ( HasMolecule env,
    HasLogFunc env,
    HasCalcSlot env
  ) =>
  CalcID ->
  WrapperTask ->
  RIO env ()
oniomCalcDriver calcID wTask = do
  -- Obtain infos from the environment.
  molT <- view moleculeL
  calcSlotT <- view calcSlotL

  let layerID = calcID ^. #molID
      calcK = calcID ^. #calcKey

  -- LOG
  logInfoS "calc-driver" $
    "Running layer " <> (display . molID2OniomHumanID $ layerID) <> ", " <> case calcK of
      ONIOMKey Original -> "high level calculation"
      ONIOMKey Inherited -> "low level calculation"

  -- Cleanup the calculation data on this layer and set the task to perform.
  atomically $ do
    cleanOutputOfCalc molT calcID
    assignTaskToCalc molT calcID wTask

  -- Polarise the layer with all information that is available above.
  molWithTask <- readTVarIO molT
  molWithPol <- maybePolariseLayer molWithTask layerID
  atomically . writeTVar molT $ molWithPol

  -- Run the specified calculation in the calculation slot. Then wait for its results.
  atomically $ putTMVar (calcSlotT ^. #input) calcID
  atomically $ do
    molWithResults <- takeTMVar (calcSlotT ^. #output)
    writeTVar molT molWithResults

----------------------------------------------------------------------------------------------------

-- | A driver function for an atomic step in Multicentre-ONIOM-n methods. Performs a single point energy
-- calculation, a gradient calculation or a hessian calculation on a given layout and builds the ONIOM
-- result from the individual results of the calculations on the layers.
--
-- *Note:* The way polarisation can be used here is a general form. It can polarise layerwise top down,
-- but only the layer directly above the layer currently handled can polarise. For exmaple in the case
-- of a 3 layer ONIOM model with real, intermediate and model system, the model system can only be
-- polarised by the intermediate system, but not the real system. The real system might influence the
-- model system by polarising the intermediate system, which then polarises the model system. Therefore
-- this is like a propagation form the outer to the inner layers. This different from the special cases
-- described in [The ONIOM Method and Its Applications](https://doi.org/10.1021/cr5004419), section
-- 2.1.4.1. Also, the scheme employed here allows QM-QM polarisation, if the QM method provides
-- charges.
multicentreOniomNDriver ::
  ( HasMolecule env,
    HasLogFunc env,
    HasInputFile env,
    HasCalcSlot env
  ) =>
  WrapperTask ->
  RIO env ()
multicentreOniomNDriver atomicTask = do
  -- Obtain environment information
  molT <- view moleculeL
  mol <- readTVarIO molT
  inputFile <- view inputFileL

  let modelOK = case inputFile ^. #model of
        ONIOMn {} -> True

  -- Check if this driver is suitable for the layout.
  unless modelOK . throwM . localExc $
    "This driver assumes a multicentre ONIOM-n layout,\
    \ but the input file specifies a different layout type."

  -- Obtain all calculations IDs.
  let allMolIDs = getAllMolIDsHierarchically mol

  -- Iterate over all layers and calculate all of them. After each high level calculation the
  -- multipoles will be collected and transfered from the high level calculation output to the
  -- actual multipole fields of the atoms, to allow for electronic embedding in deeper layers.
  forM_ allMolIDs $ \layerID -> do
    -- Iteration dependent iterations.
    molCurr <- readTVarIO molT
    let layerLens = molIDLensGen layerID
    calcKeys <-
      maybe2MThrow (localExc "Invalid layer specified") $
        Map.keys <$> molCurr ^? layerLens % #calcContext

    -- Run the original and the inherited calculation on this layer. For the original high level
    -- calculation transfer the multipoles from the calculation otuput to the corresponding fields
    -- of the atoms.
    forM_ calcKeys $ \calcK -> do
      -- Construct the current CalcID.
      let calcID = CalcID {molID = layerID, calcKey = calcK}

      -- Perform the current calculation on the current calculation of the molecule.
      oniomCalcDriver calcID atomicTask

      -- If this was a high level original calculation transfer the multipoles to the atoms.
      when (calcK == ONIOMKey Original) $ do
        molWithPolOutput <- readTVarIO molT
        molWithPolTrans <- multipoleTransfer calcID molWithPolOutput
        atomically . writeTVar molT $ molWithPolTrans
  where
    localExc = MolLogicException "multicentreOniomNDriver"

----------------------------------------------------------------------------------------------------

-- | A driver for geometry optimisations without microiteration. Does one full traversal of the
-- ONIOM molecule before a geometry displacement step. Updates can happen by an arbitrary i-PI
-- server
geomMacroDriver ::
  ( HasMolecule env,
    HasLogFunc env,
    HasInputFile env,
    HasCalcSlot env,
    HasProcessContext env,
    HasWrapperConfigs env,
    HasOutputter env
  ) =>
  RIO env ()
geomMacroDriver = do
  -- Logging.
  optStartPrintEvn <- getCurrPrintEvn
  printSpicy txtDirectOpt
  printSpicy . renderBuilder . spicyLog optStartPrintEvn $
    spicyLogMol (HashSet.fromList [Always, Task Start]) All

  -- Obtain the Pysisyphus IPI settings for communication.
  mol <- view moleculeL >>= readTVarIO
  pysisIPI <-
    let optSettings = mol ^? #calcContext % ix (ONIOMKey Original) % #input % #optimisation % #pysisyphus
     in case optSettings of
          Nothing -> throw . localExc $ "Pysisyphus connection settings could not be found."
          Just i -> return i

  -- Launch a Pysisyphus server and an i-PI client for the optimisation.
  (pysisServer, pysisClient) <- providePysis
  link pysisServer
  link pysisClient

  -- Start the loop that provides the i-PI client thread with data for the optimisation.
  let allTopAtoms = IntMap.keysSet $ mol ^. #atoms
  loop pysisIPI allTopAtoms

  -- Final logging
  optEndPrintEvn <- getCurrPrintEvn
  printSpicy . renderBuilder . spicyLog optEndPrintEvn $
    spicyLogMol (HashSet.fromList [Always, Task End]) All
  where
    localExc = SpicyIndirectionException "geomMacroDriver"

    -- The optimisation loop.
    loop pysisIPI selAtoms = do
      -- Check if the client is still runnning and expects us to provide new data.
      ipiServerWants <- atomically . takeTMVar $ pysisIPI ^. #status
      unless (ipiServerWants == Done) $ do
        -- Get communication variables with the i-PI client and Spicy.
        let ipiDataIn = pysisIPI ^. #input
            ipiPosOut = pysisIPI ^. #output
        molT <- view moleculeL

        -- Obtain the molecule before i-PI modifications.
        molOld <- readTVarIO molT
        posData <- atomically . takeTMVar $ ipiPosOut
        posVec <- case posData ^. #coords of
          NetVec vec -> Massiv.fromVectorM Par (Sz $ VectorS.length vec) vec
        molNewStruct <- updatePositionsPosVec posVec selAtoms molOld
        atomically . writeTVar molT $ molNewStruct

        -- Do a full traversal of the ONIOM tree and obtain the full ONIOM gradient.
        ipiData <- case ipiServerWants of
          WantForces -> do
            multicentreOniomNDriver WTGradient
            multicentreOniomNCollector WTGradient
            molWithForces <- readTVarIO molT
            molToForceData molWithForces
          WantHessian -> do
            multicentreOniomNDriver WTHessian
            multicentreOniomNCollector WTHessian
            molWithHessian <- readTVarIO molT
            molToHessianData molWithHessian
          Done -> do
            logErrorS "direct-opt"
              "The macro geometry driver should be done but has entered an other\
              \ calculation loop."
            throwM $
              SpicyIndirectionException "geomMacroDriver" "Data expected but not calculated?"

        -- Opt loop logging.
        optLoopPrintEnv <- getCurrPrintEvn
        let molInfo =
              renderBuilder . spicyLog optLoopPrintEnv $
                spicyLogMol (HashSet.fromList [Always, Out.Motion Out.Macro, FullTraversal]) All
        printSpicy $ sep <> molInfo

        -- Get the molecule in the new structure with its forces or hessian.
        atomically . putTMVar ipiDataIn $ ipiData

        -- Reiterating
        loop pysisIPI selAtoms


----------------------------------------------------------------------------------------------------

-- | Select the atoms that will be optimised on this hierarchy/horizontal slice.
-- @
-- selection = (real atoms of all centres in this horizontal slice)
--           - (link atoms of all centres in this horizontal slice)
--           - (atoms that also belong to deeper layers)
--           - (atoms that are real atoms in this layer but real parents (replaced by link atoms) in deeper layers)
--           + (the real parents of the link atoms of this layer)
-- @
getOptAtomsAtDepth ::
  -- | Full ONIOM tree, not just a sublayer
  Molecule ->
  -- | The depth at which to make a slice and optimise.
  Int ->
  -- | Atoms selected to be optimised at this depth.
  IntSet
getOptAtomsAtDepth mol depth =
  ( allAtomsAtDepthS -- All "real" atoms at given depth
      IntSet.\\ modelRealParentsS -- Minus atoms that are real partners with respect to deeper models
      IntSet.\\ allAtomsModelS -- Minus all atoms of deeper models.
      IntSet.\\ linkAtomsAtDepthS -- Minus all link atoms at this depth.
  )
    <> realRealPartnersS -- Plus all atoms in the layer above that are bound to link atoms of this layer
  where
    -- Obtain all non-dummy atoms that are at the given depth.
    depthSliceMol = fromMaybe mempty $ horizontalSlices mol Seq.!? depth
    allAtomsAtDepth =
      IntMap.filter (not . isDummy) . foldl' (\acc m -> acc <> m ^. #atoms) mempty $ depthSliceMol
    allAtomsAtDepthS = IntMap.keysSet allAtomsAtDepth
    linkAtomsAtDepthS = IntMap.keysSet . IntMap.filter linkF $ allAtomsAtDepth

    -- Obtain all atoms that are even deeper and belong to model systems and therefore need to be
    -- removed from the optimisation coordinates.
    modelSliceMol = fromMaybe mempty $ horizontalSlices mol Seq.!? (depth + 1)
    allAtomsModel = foldl' (\acc m -> acc <> m ^. #atoms) mempty modelSliceMol
    allAtomsModelS = IntMap.keysSet allAtomsModel
    modelRealParentsS = getRealPartners allAtomsModel

    -- Obtain the real partners one layer above of link atoms at this depth.
    realRealPartnersS = getRealPartners allAtomsAtDepth

    -- Filters to apply to remove atoms.
    linkF = isAtomLink . isLink

    -- Get real parent partner of a link atom.
    getLinkRP :: Atom -> Maybe Int
    getLinkRP a = a ^? #isLink % _IsLink % _2

    -- Get the real partners of the link atoms in a set of atoms.
    getRealPartners :: IntMap Atom -> IntSet
    getRealPartners =
      IntSet.fromList
        . fmap snd
        . IntMap.toList
        . fromMaybe mempty
        . traverse getLinkRP
        . IntMap.filter linkF

----------------------------------------------------------------------------------------------------

-- | Perform all calculations at a given depth. Allows to get gradients or hessians on a horizontal
-- slice hierarchically.
calcAtDepth ::
  ( HasMolecule env,
    HasLogFunc env,
    HasCalcSlot env
  ) =>
  Int ->
  WrapperTask ->
  RIO env ()
calcAtDepth depth task = do
  molT <- view moleculeL
  mol <- readTVarIO molT

  -- Get all calculation IDs at a given depth.
  let calcIDDepth =
        Seq.filter (\cid -> depth == Seq.length (cid ^. #molID))
          . getAllCalcIDsHierarchically
          $ mol

  -- Perform all calculations at the given depth.
  forM_ calcIDDepth $ \cid -> oniomCalcDriver cid task

----------------------------------------------------------------------------------------------------
-- | Cleans all outputs from the molecule.
cleanOutputs :: TVar Molecule -> STM ()
cleanOutputs molT = do
  mol <- readTVar molT
  let molWithEmptyOutputs = molMap (& #calcContext % each % #output .~ def) mol
  writeTVar molT molWithEmptyOutputs

----------------------------------------------------------------------------------------------------

-- | Cleans all outputs from the molecule.
cleanOutputOfCalc :: TVar Molecule -> CalcID -> STM ()
cleanOutputOfCalc molT calcID = do
  mol <- readTVar molT
  let molWithEmptyOutputs = molMap (& calcLens % #output .~ def) mol
  writeTVar molT molWithEmptyOutputs
  where
    calcLens = calcIDLensGen calcID

----------------------------------------------------------------------------------------------------

-- | Assigns the given task to each calculation in the molecule.
assignTasks :: TVar Molecule -> WrapperTask -> STM ()
assignTasks molT task = do
  mol <- readTVar molT
  let molWithTasks =
        molMap
          (& #calcContext % each % #input % #task .~ task)
          mol
  writeTVar molT molWithTasks

----------------------------------------------------------------------------------------------------

-- | Assigns the given task to the given calculation id.
assignTaskToCalc :: TVar Molecule -> CalcID -> WrapperTask -> STM ()
assignTaskToCalc molT calcID task = do
  mol <- readTVar molT
  let molWithTasks =
        molMap
          (& calcLens % #input % #task .~ task)
          mol
  writeTVar molT molWithTasks
  where
    calcLens = calcIDLensGen calcID

----------------------------------------------------------------------------------------------------

-- | Polarises a layer specified by its 'MolID' with all layers hierarchically above. The resulting
-- molecule will be the full system with the layer that was specified being polarised. The function
-- assumes, that all layers above already have been properly polarised.
maybePolariseLayer :: MonadThrow m => Molecule -> MolID -> m Molecule
maybePolariseLayer molFull molID
  | molID == Empty = return molFull
  | otherwise = do
    let layerLens = molIDLensGen molID
    molLayer <- maybe2MThrow (localExc "Layer cannot be found") $ molFull ^? layerLens
    embedding <-
      maybe2MThrow (localExc "Original calculation cannot be found") $
        molLayer ^? #calcContext % ix (ONIOMKey Original) % #input % #embedding

    polarisedLayer <- case embedding of
      Mechanical -> return molLayer
      Electronic scalingFactors -> do
        let eeScalings = fromMaybe defElectronicScalingFactors scalingFactors
        getPolarisationCloudFromAbove molFull molID eeScalings

    return $ molFull & layerLens .~ polarisedLayer
  where
    localExc = MolLogicException "polariseLayer"
