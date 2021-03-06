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
    geomMicroDriver,
  )
where

import Data.Default
import Data.Foldable
import qualified Data.IntMap as IntMap
import qualified Data.IntSet as IntSet
import Data.Massiv.Array as Massiv hiding (forM, forM_, loop, mapM)
import Data.Massiv.Array.Manifest.Vector as Massiv
import Network.Socket
import Optics hiding (Empty, view)
import RIO hiding
  ( Vector,
    lens,
    view,
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
import qualified RIO.Seq as Seq
import qualified RIO.Vector.Storable as VectorS
import Spicy.Common
import Spicy.Data
import Spicy.InputFile
import Spicy.Molecule
import Spicy.Molecule.Internal.Types (_IsLink)
import Spicy.ONIOM.Collector
import Spicy.Outputter as Out
import Spicy.RuntimeEnv
import Spicy.Wrapper.IPI.Protocol
import Spicy.Wrapper.IPI.Pysisyphus
import Spicy.Wrapper.IPI.Types
import System.Path ((</>))
import qualified System.Path as Path

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
  logInfoS logSource $
    "Full ONIOM traversal for " <> case atomicTask of
      WTEnergy -> "energy."
      WTGradient -> "gradient."
      WTHessian -> "hessian."

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

      -- If this was a high level original calculation, transfer the multipoles to the atoms and
      -- recalculate energy derivatives.
      when (calcK == ONIOMKey Original) $ do
        molWithPolOutput <- readTVarIO molT
        layerWithPolTrans <- getMolByID molWithPolOutput layerID >>= multipoleTransfer
        let molWithPolTrans = molWithPolOutput & layerLens .~ layerWithPolTrans
        atomically . writeTVar molT $ molWithPolTrans

  -- After full traversal collect all results.
  multicentreOniomNCollector
  where
    localExc = MolLogicException "multicentreOniomNDriver"
    logSource = "multi-centre ONIOM driver"

----------------------------------------------------------------------------------------------------

-- | A driver for geometry optimisations without microiteration. Does one full traversal of the
-- ONIOM molecule before a geometry displacement step. Updates can happen by an arbitrary i-PI
-- server.
geomMacroDriver ::
  ( HasMolecule env,
    HasLogFunc env,
    HasInputFile env,
    HasCalcSlot env,
    HasProcessContext env,
    HasWrapperConfigs env,
    HasOutputter env,
    HasMotion env
  ) =>
  RIO env ()
geomMacroDriver = do
  -- Logging.
  logInfoS logSource "Starting a direct geometry optimisation on the full ONIOM tree."
  optStartPrintEnv <- getCurrPrintEnv
  printSpicy txtDirectOpt
  printSpicy . renderBuilder . spicyLog optStartPrintEnv $
    spicyLogMol (HashSet.fromList [Always, Task Start]) All
  printSpicy $ "\n\n" <> optTableHeader True

  -- Obtain the Pysisyphus IPI settings and convergence treshold for communication.
  mol <- view moleculeL >>= readTVarIO
  optSettings <-
    maybe2MThrow (localExc "Optimisation settings not found on the top layer.") $
      mol ^? #calcContext % ix (ONIOMKey Original) % #input % #optimisation
  let pysisIPI = optSettings ^. #pysisyphus
      convThresh = optSettings ^. #convergence

  -- Launch a Pysisyphus server and an i-PI client for the optimisation.
  logDebugS logSource "Launching i-PI server for optimisations."
  (pysisServer, pysisClient) <- providePysis
  link pysisServer
  link pysisClient

  -- Start the loop that provides the i-PI client thread with data for the optimisation.
  let allTopAtoms = IntMap.keysSet $ mol ^. #atoms
  logDebugS logSource "Entering the optimisation recursion."
  loop pysisIPI convThresh allTopAtoms

  -- Final logging
  logInfoS logSource "Finished geometry optimisation."
  optEndPrintEnv <- getCurrPrintEnv
  printSpicy . renderBuilder . spicyLog optEndPrintEnv $
    spicyLogMol (HashSet.fromList [Always, Task End]) All
  where
    localExc = MolLogicException "geomMacroDriver"
    logSource = "MacroGeometryDriver"

    -- The optimisation loop.
    loop ::
      ( HasMolecule env,
        HasLogFunc env,
        HasInputFile env,
        HasCalcSlot env,
        HasProcessContext env,
        HasWrapperConfigs env,
        HasOutputter env,
        HasMotion env
      ) =>
      IPI ->
      GeomConv ->
      IntSet ->
      RIO env ()
    loop pysisIPI convThresh selAtoms = do
      -- Get communication variables with the i-PI client and Spicy.
      let ipiDataIn = pysisIPI ^. #input
          ipiPosOut = pysisIPI ^. #output
      molT <- view moleculeL

      -- Check if the client is still runnning and expects us to provide new data.
      ipiServerWants <- atomically . takeTMVar $ pysisIPI ^. #status
      case ipiServerWants of
        -- Terminate the loop in case the i-PI server signals convergence
        Done -> logInfoS logSource "i-PI server signaled convergence. Exiting."
        -- Pysisyphus extensions. Performs a client -> server position update and then loops back.
        WantPos -> do
          logWarnS
            logSource
            "Unusual i-PI server request for a spicy -> i-PI position update. Providing current atomic positions ..."

          -- Consume an old geometry from the server and discard.
          void . atomically . takeTMVar $ ipiPosOut

          -- Obtain current molecule geometry and update the server with those.
          updateCoords <- readTVarIO molT >>= getCoordsNetVec
          atomically . putTMVar ipiDataIn . PosUpdateData $ updateCoords

          -- Reiterating
          loop pysisIPI convThresh selAtoms

        -- Standard i-PI behaviour with server -> client position updates and client -> sever force/
        -- hessian updates.
        _ -> do
          logInfoS logSource "New geometry from i-PI server. Preparing to calculate new energy derivatives."

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
              logInfoS logSource "Calculating new gradient."
              multicentreOniomNDriver WTGradient
              multicentreOniomNCollector
              molWithForces <- readTVarIO molT
              molToForceData molWithForces
            WantHessian -> do
              logInfoS logSource "Calculating new hessian."
              multicentreOniomNDriver WTHessian
              multicentreOniomNCollector
              molWithHessian <- readTVarIO molT
              molToHessianData molWithHessian
            Done -> do
              logErrorS
                logSource
                "The macro geometry driver should be done but has entered an other\
                \ calculation loop."
              throwM $
                SpicyIndirectionException "geomMacroDriver" "Data expected but not calculated?"
            WantPos -> do
              logErrorS
                logSource
                "The i-PI server wants a position update, but position updates must not occur here."
              throwM $
                SpicyIndirectionException
                  "geomMacroDriver"
                  "Position update requested but must not happen here."

          -- Get the molecule in the new structure with its forces or hessian.
          atomically . putTMVar ipiDataIn $ ipiData

          -- If converged terminate the i-PI server by putting a "converged" file in its working
          -- directory
          molNewWithEDerivs <- readTVarIO molT
          geomChange <- calcGeomConv (IntMap.keysSet $ molOld ^. #atoms) molOld molNewWithEDerivs
          let isConverged = geomChange < convThresh
          when isConverged $ do
            logInfoS logSource "Optimisation has converged. Telling i-PI server to EXIT in the next loop."
            writeFileUTF8 (pysisIPI ^. #workDir </> Path.relFile "converged") mempty

          -- Update the Motion history types.
          motionT <- view motionL
          motionHist <- readTVarIO motionT
          let newMotion = case motionHist of
                Empty ->
                  Spicy.RuntimeEnv.Motion
                    { geomChange,
                      molecule = Nothing,
                      outerCycle = 0,
                      microCycle = (0, 0)
                    }
                _ :|> Spicy.RuntimeEnv.Motion {outerCycle} ->
                  Spicy.RuntimeEnv.Motion
                    { geomChange,
                      molecule = Nothing,
                      outerCycle = outerCycle + 1,
                      microCycle = (0, 0)
                    }
              nextMotion = motionHist |> newMotion
              step = outerCycle newMotion
          atomically . writeTVar motionT $ nextMotion

          -- Opt loop logging.
          optLoopPrintEnv <- getCurrPrintEnv
          let molInfo =
                renderBuilder . spicyLog optLoopPrintEnv $
                  spicyLogMol (HashSet.fromList [Always, Out.Motion Out.Macro, FullTraversal]) All
          printSpicy $
            sep <> "\n\n"
              <> "@ Geometry Convergence\n\
                 \----------------------\n"
              <> optTableHeader False
              <> optTableLine step Nothing geomChange
              <> "\n\n"
              <> molInfo

          -- Reiterating
          loop pysisIPI convThresh selAtoms

{-
====================================================================================================
-}

-- | A driver for geometry optimisations with microiterations. The scheme is a so called adiabatic
-- one. Let's say we focus on a horizontal slice of the ONIOM tree, and look at all layers that are
-- on this same hierarchy in the ONIOM layout, no matter if they are in the same branch or not.
-- Those are optimised together by a single optimiser (pysisyphus instance). We define a coordinate
-- system for this hierarchy, that does not influence the coordinates of atoms of any other
-- hierarchy. These coordinates are \(q^l\) and \(\partial E_\text{model} / \partial q^l = 0\).
-- Therefore, \(q^l\) contains the coordinates of all atoms of this horizontal slice, minus the
-- atoms of all models one layer below and also minus the atoms that were replaced by links in the
-- models (real parent atoms). Now, we fully converge these coordinates to a minimum. After
-- convergence we do a single step in the model systems with coordinate system \(q^m\), which
-- contains the coordinates of model atoms that are not part of even deeper models and not link atoms
-- of the model layer, as well as the real parents from one layer above. In the next recursion
-- \(q^m\) will become \(q^l\).
geomMicroDriver ::
  ( HasMolecule env,
    HasInputFile env,
    HasLogFunc env,
    HasProcessContext env,
    HasWrapperConfigs env,
    HasCalcSlot env,
    HasMotion env,
    HasOutputter env
  ) =>
  RIO env ()
geomMicroDriver = do
  -- Logging.
  logInfoS logSource "Starting a geometry optimisation with micro cycles."
  optStartPrintEnv <- getCurrPrintEnv
  printSpicy txtMicroOpt
  printSpicy . renderBuilder . spicyLog optStartPrintEnv $
    spicyLogMol (HashSet.fromList [Always, Task Start]) All

  -- Get intial information.
  molT <- view moleculeL
  mol <- readTVarIO molT

  -- Setup the pysisyphus optimisation servers per horizontal slice.
  logDebugS logSource "Launching client and server i-PI companion threads per horizontal slice ..."
  microOptHierarchy <- setupPysisServers mol

  -- Perform the optimisations steps in a mindblowing recursion ...
  -- Spawn an optimiser function at the lowest depth and this will spawn the other optimisers bottom
  -- up. When converged, the function will terminate.
  logInfoS logSource $
    "Starting the micro-cycle recursion at the most model slice of the ONIOM tree ("
      <> display (Seq.length microOptHierarchy - 1)
      <> ")."
  optAtDepth (Seq.length microOptHierarchy - 1) microOptHierarchy
  logInfoS logSource "Optimisation has converged!"

  -- Final optimisation logging
  optEndPrintEnv <- getCurrPrintEnv
  printSpicy . renderBuilder . spicyLog optEndPrintEnv $
    spicyLogMol (HashSet.fromList [Always, Task End]) All

  -- Terminate all the companion threads.
  logDebugS logSource "Terminating i-PI companion threads."
  forM_ microOptHierarchy $ \MicroOptSetup {ipiClientThread, pysisIPI} -> do
    -- Stop the pysisyphus server by gracefully by writing a magic file. Send once more gradients
    -- (dummy values more or less ...) to finish nicely and then reset all connections.
    let convFile = (pysisIPI ^. #workDir) </> Path.relFile "converged"
    writeFileUTF8 convFile mempty
    atomically . putTMVar (pysisIPI ^. #input) . dummyForces . IntMap.keysSet $ mol ^. #atoms

    -- Cancel the client and reset the communication variables to a fresh state.
    cancel ipiClientThread
    void . atomically . tryTakeTMVar $ pysisIPI ^. #input
    void . atomically . tryTakeTMVar $ pysisIPI ^. #output
    void . atomically . tryTakeTMVar $ pysisIPI ^. #status
  where
    logSource = "geomMicroDriver"
    dummyForces sel =
      ForceData
        { potentialEnergy = 0,
          forces = NetVec . VectorS.fromListN (3 * IntSet.size sel) $ [0 ..],
          virial = CellVecs (T 1 0 0) (T 0 1 0) (T 0 0 1),
          optionalData = mempty
        }

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

-- | Do a single geometry optimisation step with a *running* pysisyphus instance at a given depth.
-- Takes care that the gradients are all calculated and that the microcycles above have converged.
optAtDepth ::
  ( HasMolecule env,
    HasLogFunc env,
    HasCalcSlot env,
    HasProcessContext env,
    HasMotion env,
    HasOutputter env
  ) =>
  Int ->
  Seq MicroOptSetup ->
  RIO env ()
optAtDepth depth' microOptSettings'
  | depth' > Seq.length microOptSettings' = throwM $ MolLogicException "optStepAtDepth" "Requesting optimisation of a layer that has no microoptimisation settings"
  | depth' < 0 = return ()
  | otherwise = do
    logInfoS logSMicroD $ "Starting micro-cyle optimisation on layer " <> display depth'
    untilConvergence depth' microOptSettings'
    logInfoS logSMicroD $ "Finished micro-cycles of layer " <> display depth'
  where
    logSMicroD :: LogSource
    logSMicroD = "geomMicroDriver"

    ------------------------------------------------------------------------------------------------
    (!??) :: MonadThrow m => Seq a -> Int -> m a
    sa !?? i = case sa Seq.!? i of
      Nothing -> throwM $ IndexOutOfBoundsException (Sz $ Seq.length sa) i
      Just v -> return v

    ------------------------------------------------------------------------------------------------
    coordinateSync ::
      (HasMolecule env, HasLogFunc env) =>
      -- | Current optimisation depth
      Int ->
      -- | The optimisation settings of this layer used to optimised this layer
      Seq MicroOptSetup ->
      RIO env ()
    coordinateSync depth mos = do
      logDebugS logSMicroD $
        "(slice " <> display depth <> ") synchronising coordinates with i-PI server (spicy -> i-PI)"

      -- Settings of this layer
      optSettings <- mos !?? depth
      let posOut = optSettings ^. #pysisIPI % #output
          dataIn = optSettings ^. #pysisIPI % #input

      -- Consume and discard the invalid step from the server.
      void . atomically . takeTMVar $ posOut

      -- Get the current state of the molecule and send it to the Pysisyphus instance, to update
      -- those coordinates before doing a step.
      molCurrCoords <- view moleculeL >>= readTVarIO >>= getCoordsNetVec
      atomically . putTMVar dataIn . PosUpdateData $ molCurrCoords

    ------------------------------------------------------------------------------------------------
    updateGeomFromPysis ::
      (HasMolecule env, HasLogFunc env) =>
      -- | Current optimisation depth
      Int ->
      Seq MicroOptSetup ->
      RIO env ()
    updateGeomFromPysis depth mos = do
      logDebugS logSMicroD $ "(slice " <> display depth <> ") new geometry for slice from i-PI."

      -- Initial information
      molT <- view moleculeL
      molPreStep <- readTVarIO molT
      optSettings <- mos !?? depth
      let posOut = optSettings ^. #pysisIPI % #output
          allRealAtoms = IntMap.keysSet $ molPreStep ^. #atoms

      -- Do the position update.
      posVec <- do
        d <- atomically . takeTMVar $ posOut
        let v = getNetVec $ d ^. #coords
        Massiv.fromVectorM Par (Sz $ VectorS.length v) v
      molNewCoords <- updatePositionsPosVec posVec allRealAtoms molPreStep
      atomically . writeTVar molT $ molNewCoords

    ------------------------------------------------------------------------------------------------
    recalcGradsAbove ::
      (HasMolecule env, HasLogFunc env, HasCalcSlot env) =>
      -- | Current optimisation depth
      Int ->
      RIO env ()
    recalcGradsAbove depth = do
      logDebugS logSMicroD $ "(slice " <> display depth <> ") Step invalidated gradients. Recalculating gradients above current slice."

      -- Initial information.
      molT <- view moleculeL

      -- For all layers above recalculate the gradients. Then collect everything possible again and
      -- transform into a valid ONIOM representation.
      forM_ (allAbove depth) $ \d -> calcAtDepth d WTGradient
      molInvalidG <- readTVarIO molT
      unless (depth == 0) $ collectorDepth (max 0 $ depth - 1) molInvalidG >>= atomically . writeTVar molT

      logDebugS logSMicroD $ "(slice " <> display depth <> ") Finished with gradient above."
      where
        allAbove d = if d >= 0 then [0 .. d - 1] else []

    ------------------------------------------------------------------------------------------------
    recalcGradsAtDepth ::
      (HasMolecule env, HasLogFunc env, HasCalcSlot env) =>
      -- | Current optimisation depth
      Int ->
      RIO env ()
    recalcGradsAtDepth depth = do
      logDebugS logSMicroD $ "(slice " <> display depth <> ") Recalculating gradients in current slice."

      -- Initial information.
      molT <- view moleculeL

      -- Recalculate all layers at this depth slice and update the molecule state with this information.
      calcAtDepth depth WTGradient
      molPostStep <- readTVarIO molT >>= collectorDepth depth
      atomically . writeTVar molT $ molPostStep

      logDebugS logSMicroD $ "(slice " <> display depth <> ") Finished with current slice's gradients."

    ------------------------------------------------------------------------------------------------
    provideForces ::
      (HasMolecule env, HasLogFunc env) =>
      -- | Current optimisation depth
      Int ->
      Seq MicroOptSetup ->
      RIO env ()
    provideForces depth mos = do
      -- Initial information.
      optSettings <- mos !?? depth
      let dataIn = optSettings ^. #pysisIPI % #input

      -- Obtain (already transformed!) ONIOM gradients.
      molWithGrads <- view moleculeL >>= readTVarIO
      transGradReal <-
        maybe2MThrow (SpicyIndirectionException "untilConvergence" "Gradients missing") $
          molWithGrads ^? #energyDerivatives % #gradient % _Just

      -- Construct the data for i-PI
      let forcesBohrReal = compute @S . Massiv.map (convertA2B . (* (-1))) . getVectorS $ transGradReal
          forceData =
            ForceData
              { potentialEnergy = fromMaybe 0 $ molWithGrads ^. #energyDerivatives % #energy,
                forces = NetVec . Massiv.toVector $ forcesBohrReal,
                virial = CellVecs (T 1 0 0) (T 0 1 0) (T 0 0 1),
                optionalData = mempty
              }

      -- Send forces to i-PI
      logDebugS logSMicroD $ "(slice " <> display depth <> ") Providing forces to i-PI."
      atomically . putTMVar dataIn $ forceData
      where
        convertA2B v = v / (angstrom2Bohr 1)

    ------------------------------------------------------------------------------------------------
    calcConvergence ::
      (HasMotion env) =>
      -- | Current optimisation depth
      Int ->
      Seq MicroOptSetup ->
      -- | Molecule before the step
      Molecule ->
      -- | Molecule after the step.
      Molecule ->
      -- | The geometry change between steps and the new 'Motion' information constructed from it.
      RIO env (GeomConv, Motion)
    calcConvergence depth mos molPre molPost = do
      -- Initial information
      optSettings <- mos !?? depth
      let atomDepthSelection = optSettings ^. #atomsAtDepth
      motionT <- view motionL

      -- Calculate the values characterising the geometry changes.
      geomChange <- calcGeomConv atomDepthSelection molPre molPost

      -- Build the next value of the motion history and add it to the history.
      motionHist <- readTVarIO motionT
      let lastMotionAtDepth = getLastMotionOnLayer motionHist
          lastCounterAtDepth = fromMaybe 0 $ snd . microCycle <$> lastMotionAtDepth
          newMotion = case motionHist of
            Empty ->
              Spicy.RuntimeEnv.Motion
                { geomChange,
                  molecule = Nothing,
                  outerCycle = 0,
                  microCycle = (depth, 0)
                }
            _ :|> Spicy.RuntimeEnv.Motion {outerCycle} ->
              Spicy.RuntimeEnv.Motion
                { geomChange,
                  molecule = Nothing,
                  outerCycle,
                  microCycle = (depth, lastCounterAtDepth + 1)
                }
          nextMotion = motionHist |> newMotion
      atomically . writeTVar motionT $ nextMotion

      -- Return the calculated geometry change.
      return (geomChange, newMotion)
      where
        getLastMotionOnLayer :: Seq Motion -> Maybe Motion
        getLastMotionOnLayer Empty = Nothing
        getLastMotionOnLayer (ini :|> l) =
          let lastDepth = l ^. #microCycle % _1
           in if lastDepth == depth
                then Just l
                else getLastMotionOnLayer ini

    ------------------------------------------------------------------------------------------------
    logOptStep ::
      (HasMolecule env, HasOutputter env, HasLogFunc env) =>
      -- | Current optimisation depth
      Int ->
      -- | Geometry change between steps.
      GeomConv ->
      -- | 'Motion' information for this geometry optimisation step.
      Motion ->
      RIO env ()
    logOptStep depth geomChange motion = do
      logInfoS logSMicroD $ "(slice " <> display depth <> ") Finished micro-cycle " <> displayShow (motion ^. #microCycle)

      -- Initial information
      mol <- view moleculeL >>= readTVarIO

      microStepPrintEnv <- getCurrPrintEnv
      let -- Maximum depth of the ONIOM tree.
          maxDepth = (+ (- 1)) . Seq.length . horizontalSlices $ mol

          -- 'MolID's at the current given depth.
          molIDsAtSlice =
            fmap Layer
              . Seq.filter (\mid -> Seq.length mid == depth)
              . getAllMolIDsHierarchically
              $ mol

          -- Auto-generated output for each layer involved in this step.
          layerInfos =
            renderBuilder
              . foldl (<>) mempty
              . fmap
                ( spicyLog microStepPrintEnv
                    . spicyLogMol (HashSet.fromList [Always, Out.Motion Out.Micro])
                )
              $ molIDsAtSlice

          -- Auto-generated output for the full ONIOM tree.
          molInfo =
            renderBuilder . spicyLog microStepPrintEnv $
              spicyLogMol
                (HashSet.fromList [Always, Out.Motion Out.Micro, Out.Motion Out.Macro, FullTraversal])
                All

      -- Write information about the molecule to the output file.
      printSpicy $
        "\n\n"
          <> "@ Geometry Convergence\n\
             \----------------------\n"
          <> optTableHeader ((snd . microCycle $ motion) == 0 && depth == 0)
          <> optTableLine (snd . microCycle $ motion) (Just depth) geomChange
          <> "\n\n"
          <> if depth == maxDepth
            then molInfo
            else layerInfos

    ------------------------------------------------------------------------------------------------
    untilConvergence ::
      ( HasMolecule env,
        HasLogFunc env,
        HasCalcSlot env,
        HasProcessContext env,
        HasMotion env,
        HasOutputter env
      ) =>
      Int ->
      Seq MicroOptSetup ->
      RIO env ()
    untilConvergence depth microOptSettings = do
      -- Initial information.
      microSettingsAtDepth <- microOptSettings !?? depth
      let geomConvCriteria = microSettingsAtDepth ^. #geomConv
          ipiStatusVar = microSettingsAtDepth ^. #pysisIPI % #status

      -- Follow the requests of the i-PI server.
      ipiServerWants <- atomically . takeTMVar $ ipiStatusVar
      case ipiServerWants of
        -- Terminate the optimisation loop in case the i-PI server signals convergence.
        Done ->
          logWarnS logSMicroD $
            "(slice " <> display depth <> ") i-PI server signaled an exit. It should never terminate by itself ..."
        -- Provide new positions to the i-PI server.
        WantPos -> coordinateSync depth microOptSettings >> untilConvergence depth microOptSettings
        -- Micro-cycle optimisation cannot use Hessian information at the moment, as I haven't
        -- thought about sub-tree hessian updates, yet.
        WantHessian -> do
          logErrorS
            logSMicroD
            "The i-PI server wants a hessian update, but hessian updates subtrees are not implemented yet."
          throwM $ SpicyIndirectionException "geomMicroDriver" "Hessian updates not implemented yet."

        -- Normal i-PI update, where the client communicates current forces to the the server.
        WantForces -> do
          molPreStep <- view moleculeL >>= readTVarIO

          -- Apply the step as obtained from Pysisyphus.
          updateGeomFromPysis depth microOptSettings

          -- Recalculate the gradients above. The position update invalidates the old ones.
          recalcGradsAbove depth

          -- Optimise the layers above.
          logDebugS logSMicroD $ "(slice " <> display depth <> ") Recursively entering micro-cycles in slice above."
          optAtDepth (depth - 1) microOptSettings
          logDebugS logSMicroD $ "(slice " <> display depth <> ") Finished with micro-cycles in slices above."

          -- Calculate forces in the new geometry for the current layer only.
          recalcGradsAtDepth depth

          -- Molecule with valid gradients up to this depth after the step.
          molPostStep <- view moleculeL >>= readTVarIO

          -- Construct force data, that we send to i-PI for this slice and send it.
          -- A collector up to the current depth will collect all force data and transform the
          -- gradients of all layers up to current depth into the real system gradient, which is
          -- then completely sent to Pysisyphus.
          provideForces depth microOptSettings

          -- Calculate geometry convergence and update the motion environment.
          (geomChange, newMotion) <- calcConvergence depth microOptSettings molPreStep molPostStep

          -- Logging post step.
          logOptStep depth geomChange newMotion

          -- Decide if to do more iterations.
          if geomChange < geomConvCriteria
            then return ()
            else untilConvergence depth microOptSettings

----------------------------------------------------------------------------------------------------

-- | Per slice settings for the optimisation.
data MicroOptSetup = MicroOptSetup
  { -- | Moving atoms for this slice
    atomsAtDepth :: !IntSet,
    -- | The i-PI client thread. To be killed in the end.
    ipiClientThread :: Async (),
    -- | Pysisyphus i-PI server thread. To be gracefully terminated when done.
    ipiServerThread :: Async (),
    -- | IPI communication and process settings.
    pysisIPI :: !IPI,
    -- | Geometry convergence.
    geomConv :: GeomConv
  }

instance (k ~ A_Lens, a ~ IntSet, b ~ a) => LabelOptic "atomsAtDepth" k MicroOptSetup MicroOptSetup a b where
  labelOptic = lens atomsAtDepth $ \s b -> s {atomsAtDepth = b}

instance (k ~ A_Lens, a ~ Async (), b ~ a) => LabelOptic "ipiClientThread" k MicroOptSetup MicroOptSetup a b where
  labelOptic = lens ipiClientThread $ \s b -> s {ipiClientThread = b}

instance (k ~ A_Lens, a ~ Async (), b ~ a) => LabelOptic "ipiServerThread" k MicroOptSetup MicroOptSetup a b where
  labelOptic = lens ipiServerThread $ \s b -> s {ipiServerThread = b}

instance (k ~ A_Lens, a ~ IPI, b ~ a) => LabelOptic "pysisIPI" k MicroOptSetup MicroOptSetup a b where
  labelOptic = lens pysisIPI $ \s b -> s {pysisIPI = b}

instance (k ~ A_Lens, a ~ GeomConv, b ~ a) => LabelOptic "geomConv" k MicroOptSetup MicroOptSetup a b where
  labelOptic = lens geomConv $ \s b -> s {geomConv = b}

-- | Create one Pysisyphus i-PI instance per layer that takes care of the optimisations steps at a
-- given horizontal slice. It returns relevant optimisation settings for each layer to be used by
-- other functions, that actually do the optimisation.
setupPysisServers ::
  ( HasInputFile env,
    HasLogFunc env,
    HasProcessContext env,
    HasWrapperConfigs env
  ) =>
  Molecule ->
  RIO env (Seq MicroOptSetup)
setupPysisServers mol = do
  -- Get directories to work in from the input file.
  inputFile <- view inputFileL
  scratchDirAbs <- liftIO . Path.dynamicMakeAbsoluteFromCwd . getDirPath $ inputFile ^. #scratch

  -- Make per slice information.
  let molSlices = horizontalSlices mol
      optAtomsSelAtDepth = getOptAtomsAtDepth mol <$> Seq.fromList [0 .. Seq.length molSlices]
      allAtoms = molFoldl (\acc m -> acc <> (m ^. #atoms)) mempty mol
      optAtomsAtDepth = fmap (IntMap.restrictKeys allAtoms) optAtomsSelAtDepth

  -- Get an IntMap of atoms for Pysisyphus. These are the atoms of the real layer. Freezes to only
  -- optimise a subsystem are employed later.
  let allRealAtoms = mol ^. #atoms

  fstMolsAtDepth <-
    maybe2MThrow (localExc "a slice of the molecule seems to be empty") $
      traverse (Seq.!? 0) molSlices
  optSettingsAtDepthRaw <-
    maybe2MThrow (localExc "an original calculation context on some level is missing") $
      forM fstMolsAtDepth (^? #calcContext % ix (ONIOMKey Original) % #input % #optimisation)
  let optSettingsAtDepth =
        Seq.mapWithIndex
          ( \i opt ->
              let freeAtomsAtThisDepth = IntMap.keysSet . fromMaybe mempty $ optAtomsAtDepth Seq.!? i
                  frozenAtomsAtThisDepth = IntMap.keysSet $ allRealAtoms `IntMap.withoutKeys` freeAtomsAtThisDepth
               in opt
                    & #pysisyphus % #socketAddr .~ SockAddrUnix (mkScktPath scratchDirAbs i)
                    & #pysisyphus % #workDir .~ Path.toAbsRel (mkPysisWorkDir scratchDirAbs i)
                    & #pysisyphus % #initCoords .~ (mkPysisWorkDir scratchDirAbs i </> Path.relFile "InitCoords.xyz")
                    & #pysisyphus % #oniomDepth ?~ i
                    & #freezes %~ (<> frozenAtomsAtThisDepth)
          )
          optSettingsAtDepthRaw
  threadsAtDepth <- mapM (providePysisAbstract True allRealAtoms) optSettingsAtDepth

  return $
    Seq.zipWith3
      ( \a os (st, ct) ->
          MicroOptSetup
            { atomsAtDepth = IntMap.keysSet a,
              ipiClientThread = ct,
              ipiServerThread = st,
              pysisIPI = os ^. #pysisyphus,
              geomConv = os ^. #convergence
            }
      )
      optAtomsAtDepth
      optSettingsAtDepth
      threadsAtDepth
  where
    localExc = MolLogicException "setupPsysisServers"
    mkScktPath sd i = Path.toString $ sd </> Path.relFile ("pysis_slice_" <> show i <> ".socket")
    mkPysisWorkDir pd i = pd </> Path.relDir ("pysis_slice" <> show i)

{-
====================================================================================================
-}

-- | Cleans all outputs from the molecule.
cleanOutputs :: TVar Molecule -> STM ()
cleanOutputs molT = do
  mol <- readTVar molT
  let molWithEmptyOutputs = molMap (& #calcContext % each % #output .~ def) mol
  writeTVar molT molWithEmptyOutputs

----------------------------------------------------------------------------------------------------

-- | Cleans the output of a single calculation.
cleanOutputOfCalc :: TVar Molecule -> CalcID -> STM ()
cleanOutputOfCalc molT calcID = do
  mol <- readTVar molT
  let molWithEmptyOutput = mol & calcLens % #output .~ def
  writeTVar molT molWithEmptyOutput
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
