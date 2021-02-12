module Spicy.Wrapper.Internal.Output.XTB
  ( parseXTBout,
    xtbMultipoles,
    parseXTBgradient,
    parseXTBhessian,
    RawXTB(..)
  )
where

import RIO hiding (takeWhile)
import RIO.Char
import RIO.Text hiding (takeWhile)
import qualified RIO.ByteString.Lazy as BL
import qualified RIO.Vector as V
import Spicy.Math.Spherical
import Spicy.Common
import Spicy.Molecule.Internal.Types
import Spicy.Wrapper.Internal.Output.Generic
import Data.Attoparsec.Text
import Data.Aeson
import qualified Data.Massiv.Array as VM

data RawXTB = RawXTB
  { totalEnergy :: Double,
    partialCharges :: Vector Double,
    atomicDipoles :: Vector (Vector Double),
    atomicQuadrupoles :: Vector (Vector Double)
  }
  deriving (Generic,Show)

instance FromJSON RawXTB where
  parseJSON = withObject "xtbout" $ \o -> RawXTB
    <$> o .: "total energy"
    <*> o .: "partial charges"
    <*> o .: "atomic dipole moments"
    <*> o .: "atomic quadrupole moments"

orderPoles :: MonadThrow m => RawXTB -> m [CMultipoles]
orderPoles RawXTB{..} = do
  -- Sanity check: Do we have information for every atom?
  let mmono = fmap CMonopole partialCharges
  mdi <- sequenceA $ mkDipole <$> atomicDipoles
  mquad <- sequenceA $ mkQuadrupole <$> atomicQuadrupoles
  return . V.toList $ V.zipWith3 CMultipoles (Just <$> mmono) (Just <$> mdi) (Just <$> mquad)
      unless (length vec == 3) . throwM $ DataStructureException "orderPoles.mkDipole" "Dipole has incorrect number of entries!"
>>>>>>> b358810... Multipole parsing from XTB
      x <- vec !?? 0
      y <- vec !?? 1
      z <- vec !?? 2
      return CDipole
        { c100 = x
        , c010 = y
        , c001 = z }
    -- Assumes xx, xy, yy, xz, yz, zz ordering in the xtb output!
    mkQuadrupole :: MonadThrow m => Vector Double -> m CQuadrupole
    mkQuadrupole vec = do
<<<<<<< HEAD
      unless (RIO.length vec == 6) . throwM $ DataStructureException "orderPoles.mkQuadrupole" "Quadrupole has incorrect number of entries!"
=======
      unless (length vec == 6) . throwM $ DataStructureException "orderPoles.mkQuadrupole" "Quadrupole has incorrect number of entries!"
>>>>>>> b358810... Multipole parsing from XTB
      xx <- vec !?? 0
      xy <- vec !?? 1
      yy <- vec !?? 2
      xz <- vec !?? 3
      yz <- vec !?? 4
      zz <- vec !?? 5
      return CQuadrupole
        { c200 = xx
        , c020 = yy
        , c002 = zz
        , c110 = xy
        , c101 = xz
        , c011 = yz }

-- | Parse the JSON file that XTB can be made to write.
parseXTBout :: MonadThrow m => BL.ByteString -> m RawXTB
parseXTBout = maybe (throwM $ ParserException "parseXTBout") return . decode

xtbMultipoles :: MonadThrow m => RawXTB -> m [Multipoles]
xtbMultipoles =
  fmap fmap fmap cartesianToSpherical -- Yes, what about it?
  . maybe (throwM $ DataStructureException "xtbMultipoles" "XTB poles could not be processed") return
  . orderPoles

-- | Parse the 'gradient' output file of XTB. XTB must be told to write this file, it will not do so
-- on a normal run. This file can contain multiple gradients if the XTB calculation is a compound
-- calculation -- This isn't currently dealt with.
parseXTBgradient :: Parser (VectorS Double)
parseXTBgradient = do
  _ <- string "$grad" <* skipLine
  _ <- skipLine
  _ <- many1 parseCoordinates
  gradients <- many1' parseGradients
  let vec = VectorS . VM.fromList VM.Seq . loseStructure $ gradients
  _ <- string "$end"
  return vec
    where
      parseCoordinates = do
        x <- skipHorizontalSpace *> double
        y <- skipHorizontalSpace *> double
        z <- skipHorizontalSpace *> double
        name <- skipLine
        return (name,x,y,z)
      parseGradients = do
        x <- skipHorizontalSpace *> fortranDouble
        y <- skipHorizontalSpace *> fortranDouble
        z <- skipHorizontalSpace *> fortranDouble
        _ <- skipLine
        return (x,y,z)
      loseStructure :: [(a,a,a)] -> [a] -- This feels like i'm begging for a memory leak
      loseStructure [] = []
      loseStructure ((x,y,z):xs) = x:y:z: loseStructure xs


-- | Utility: Skip the rest of the line.
skipLine :: Parser Text
skipLine = pack <$> manyTill (notChar '\n') (char '\n')

-- | Haskell's 'read' and attoparsec's 'double' don't recognize the format
-- for fortran's double precision numbers, i.e. 1.00D-03. This parser is a
-- workaround for this issue. This could move to Spicy.Common later?
fortranDouble :: Parser Double
fortranDouble = do
  raw <- fmap replaceD . unpack <$> takeWhile (not.isSpace)
  case readMaybe raw of -- Is there a readMaybe for Text? Then we could skip the intermediate string 
    Just aDouble -> pure aDouble
    Nothing -> fail "Failed to read Fortran real!"
  where
    replaceD c = if c == 'D' then 'E' else c

parseXTBhessian :: Parser (MatrixS Double)
parseXTBhessian = do
  _ <- string "$hessian"
  doubleSquareMatrix <* skipSpace <* endOfInput
