-- |
-- Module      : Spicy.Wrapper.Internal.Input.Representation
-- Description : Preparing program-specific text representations
-- Copyright   : Phillip Seeber, Sebastian Seidenath, 2021
-- License     : GPL-3
-- Maintainer  : phillip.seeber@uni-jena.de
-- Stability   : experimental
-- Portability : POSIX, Windows
--
-- This module provides functions to construct program-specific
-- text representations for coordinate and multipole data.
module Spicy.Wrapper.Internal.Input.Representation
  ( simpleCartesianAngstrom,
    coord,
    xtbMultipoleRep,
    psi4MultipoleRep,
    turbomoleMultipoleRep,
  )
where

import qualified Data.IntMap as IntMap
import Data.Massiv.Array as Massiv hiding (drop, forM_)
import Data.Text.Lazy (toStrict)
import qualified Data.Text.Lazy.Builder as Builder
import Formatting as F
import Optics hiding (element)
import RIO hiding ((^.))
import qualified RIO.Text as Text
import RIO.Writer
import Spicy.Common
import Spicy.Data
import Spicy.Molecule

-- | Make a simple coordinate representation of the current Molecule layer.
-- This function takes care to remove all dummy atoms.
simpleCartesianAngstrom :: MonadThrow m => Molecule -> m Text
simpleCartesianAngstrom mol = Text.unlines . drop 2 . Text.lines <$> writeXYZ (isolateMoleculeLayer mol)

----------------------------------------------------------------------------------------------------

-- | Serialiase a geometry to a turbomole style @$coord@ block (does not contain @$end@!).
coord :: MonadThrow m => Molecule -> m Text
coord mol = do
  let ats = IntMap.filter (not . isDummy) $ mol ^. #atoms
      repWriter :: Writer Text () = forM_ ats $ \Atom {..} -> do
        let coords = compute @U . Massiv.map angstrom2Bohr . getVectorS $ coordinates
        tell "  "
        Massiv.mapM_ (\c -> tell $ tshow c <> "  ") coords
        tell "  "
        tellN . Text.toLower . tshow $ element
  return . execWriter $ repWriter

----------------------------------------------------------------------------------------------------

-- | Generate the multipole representation accepted by XTB. Must be in its own file.
xtbMultipoleRep ::
  (MonadThrow m) =>
  -- | The __current__ 'Molecule' layer for which to perform the calculation. The multipoles must
  -- therefore already be present and multipole centres must be marked as Dummy atoms.
  Molecule ->
  m Text
xtbMultipoleRep mol = do
  pointCharges <- molToPointCharges mol
  let pointChargeVecs = Massiv.innerSlices pointCharges
      frmt = float F.% " " F.% float F.% " " F.% float F.% " " F.% float F.% " 99\n"
      chargeLines = Massiv.foldMono (mp2Text (XTB undefined) frmt) pointChargeVecs
      countLine = (Builder.fromText . tShow . length $ pointChargeVecs) <> "\n"
      xtbBuilder = countLine <> chargeLines
  return . toStrict . Builder.toLazyText $ xtbBuilder

----------------------------------------------------------------------------------------------------

-- | Generates the multipole representation for Psi4.
psi4MultipoleRep ::
  (MonadThrow m) =>
  -- | The __current__ 'Molecule' layer for which to perform the calculation. The multipoles must
  -- therefore already be present and multipole centres must be marked as Dummy atoms.
  Molecule ->
  m Text
psi4MultipoleRep mol = do
  pointCharges <- molToPointCharges mol
  let pointChargeVecs = Massiv.innerSlices pointCharges
      fmrt = "Chrgfield.extern.addCharge(" F.% float F.% ", " F.% float F.% ", " F.% float F.% ", " F.% float F.% ")\n"
      chargeLines = Massiv.foldMono (mp2Text (Psi4 undefined) fmrt) pointChargeVecs
      settingsLine = "psi4.set_global_option_python('EXTERN', Chrgfield.extern)"
      psi4Builder = "Chrgfield = QMMM()\n" <> chargeLines <> settingsLine
  return . toStrict . Builder.toLazyText $ psi4Builder

----------------------------------------------------------------------------------------------------

-- | Multipole representation as point charges in turbomole. Prints only the lines, not the block,
-- that contains them.
turbomoleMultipoleRep ::
  (MonadThrow m) =>
  -- | The __current__ 'Molecule' layer for which to perform the calculation. The multipoles must
  -- therefore already be present and multipole centres must be marked as Dummy atoms.
  Molecule ->
  m Text
turbomoleMultipoleRep mol = do
  pointCharges <- molToPointCharges mol
  let pointChargeVecs = Massiv.innerSlices pointCharges
      frmt = "  " F.% " " F.% float F.% " " F.% float F.% " " F.% float F.% " " F.% float F.% "\n"
      chargeLines = Massiv.foldMono (mp2Text (Turbomole undefined) frmt) pointChargeVecs
  return . toStrict . Builder.toLazyText $ chargeLines

----------------------------------------------------------------------------------------------------

-- | Auxilliary function which formats multipoles. Said vector must contain at least 4 entries,
-- thus unsafe and not to be exported. Coordinate units depend on the program.
mp2Text ::
  (Massiv.Manifest r Ix1 Double) =>
  Program ->
  -- | Formatter, which has three formatters for the cartesian components and one for the charge.
  Format Builder.Builder (Double -> Double -> Double -> Double -> t) ->
  -- | Array of point charges
  Massiv.Vector r Double ->
  t
mp2Text software fmrt vec =
  let q = vec Massiv.! 3
      x = conv $ vec Massiv.! 0
      y = conv $ vec Massiv.! 1
      z = conv $ vec Massiv.! 2
   in case software of
        Psi4 _ -> bformat fmrt q x y z
        Turbomole _ -> bformat fmrt x y z q
        XTB _ -> bformat fmrt q x y z
  where
    conv = case software of
      Psi4 _ -> id
      XTB _ -> id
      Turbomole _ -> angstrom2Bohr
