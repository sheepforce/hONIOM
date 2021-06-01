-- |
-- Module      : Spicy.Data
-- Description : Data to lookup for chemical systems
-- Copyright   : Phillip Seeber, 2021
-- License     : GPL-3
-- Maintainer  : phillip.seeber@uni-jena.de
-- Stability   : experimental
-- Portability : POSIX, Windows
--
-- This module provides scientific constants, conversion factors and element data.
module Spicy.Data
  ( covalentRadii,
    defCovScaling,
    defElectronicScalingFactors,
    angstrom2Bohr,
    bohr2Angstrom,
  )
where

import RIO
import qualified RIO.Map as Map
import qualified RIO.Seq as Seq
import Spicy.Molecule.Internal.Types

-- |
-- Covalent radii of elements in Angstrom taken from
-- <https://en.wikipedia.org/wiki/Covalent_radius Wikipedia>
covalentRadii :: Map Element Double
covalentRadii =
  Map.fromList
    [ (H, 0.31),
      (He, 0.28),
      (Li, 1.28),
      (Be, 0.96),
      (B, 0.84),
      (C, 0.76),
      (N, 0.71),
      (O, 0.66),
      (F, 0.57),
      (Ne, 0.58),
      (Na, 1.66),
      (Mg, 1.41),
      (Al, 1.21),
      (Si, 1.11),
      (P, 1.07),
      (S, 1.05),
      (Cl, 1.02),
      (Ar, 1.06),
      (K, 2.03),
      (Ca, 1.76),
      (Sc, 1.70),
      (Ti, 1.60),
      (V, 1.53),
      (Cr, 1.39),
      (Mn, 1.61),
      (Fe, 1.52),
      (Co, 1.50),
      (Ni, 1.24),
      (Cu, 1.32),
      (Zn, 1.22),
      (Ga, 1.22),
      (Ge, 1.20),
      (As, 1.19),
      (Se, 1.20),
      (Br, 1.20),
      (Kr, 1.16),
      (Rb, 2.20),
      (Sr, 1.95),
      (Y, 1.90),
      (Zr, 1.75),
      (Nb, 1.64),
      (Mo, 1.54),
      (Tc, 1.47),
      (Ru, 1.46),
      (Rh, 1.42),
      (Pd, 1.39),
      (Ag, 1.45),
      (Cd, 1.44),
      (In, 1.42),
      (Sn, 1.39),
      (Sb, 1.39),
      (Te, 1.38),
      (I, 1.39),
      (Xe, 1.40),
      (Cs, 2.44),
      (Ba, 2.15),
      (Lu, 1.87),
      (Hf, 1.75),
      (Ta, 1.70),
      (W, 1.62),
      (Re, 1.51),
      (Os, 1.44),
      (Ir, 1.41),
      (Pt, 1.36),
      (Au, 1.36),
      (Hg, 1.32),
      (Tl, 1.45),
      (Pb, 1.46),
      (Bi, 1.48),
      (Po, 1.40),
      (At, 1.50),
      (Rn, 1.50),
      (Fr, 2.60),
      (Ra, 2.21),
      (La, 2.07),
      (Ce, 2.04),
      (Pr, 2.03),
      (Nd, 2.01),
      (Pm, 1.99),
      (Sm, 1.98),
      (Eu, 1.98),
      (Gd, 1.96),
      (Tb, 1.50),
      (Dy, 1.92),
      (Ho, 1.92),
      (Er, 1.89),
      (Tm, 1.90),
      (Yb, 1.87),
      (Ac, 1.92),
      (Th, 2.06),
      (Pa, 2.00),
      (U, 1.96),
      (Np, 1.90),
      (Pu, 1.87),
      (Am, 1.80),
      (Cm, 1.69)
    ]

----------------------------------------------------------------------------------------------------

-- |
-- Default scaling factor for search of covalent bonds in a molecule.
defCovScaling :: Double
defCovScaling = 1.3

----------------------------------------------------------------------------------------------------

-- |
-- Default scaling factors for electronic embedding in ONIOM as given in the literature. The first
-- value in the sequence will be used to scale the multipoles one bond away from a capped atom, the
-- second entry multipoles two bonds away and so on.

-- TODO (phillip|p=50|#Wrong) - These are just some made up values. Lookup the real ones in literature.
defElectronicScalingFactors :: Seq Double
defElectronicScalingFactors = Seq.fromList [0.2, 0.4, 0.6, 0.8]

----------------------------------------------------------------------------------------------------

-- |
-- Conversion from Angstrom to Bohr.
angstrom2Bohr :: Double -> Double
angstrom2Bohr lenghtInAngstrom = lenghtInAngstrom * 1.889725989

----------------------------------------------------------------------------------------------------

-- |
-- Conversion from Bohr to Angstrom.
bohr2Angstrom :: Double -> Double
bohr2Angstrom lengthInBohr = lengthInBohr / (angstrom2Bohr 1)
