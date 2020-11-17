{-|
Module      : Spicy.Wrapper.Input.Shallow
Description : Provides writers for shallow wrappers to quantum chemistry and molecular mechanics software.
Copyright   : Phillip Seeber, 2020
License     : GPL-3
Maintainer  : phillip.seeber@uni-jena.de
Stability   : experimental
Portability : POSIX, Windows

This module provides methods to write input files to quantum chemistry programs by means of shallow
wrappers. That means this wrapper tries to be as agnostic as possible of the underlying program and
simply fills in placeholders into a template file.
-}
module Spicy.Wrapper.Internal.Input.Shallow
  ( translate2Input
  )
where
import           Control.Lens            hiding ( (.=) )
import           Data.Aeson
import           RIO                     hiding ( (^.)
                                                , (^?)
                                                )
import qualified RIO.Text                      as Text
import qualified RIO.Text.Lazy                 as Text
                                                ( toStrict )
import           Spicy.Class
import           Spicy.Generic
import           Spicy.Molecule.Internal.Util
import           Spicy.Molecule.Internal.Writer
import qualified System.Path                   as Path
import           Text.Mustache

{-|
This function takes a Mustache template file and replaces the values. There are values which are not
always provided by the wrapper input ('Maybe'). Those values will have a @Nothing@ as a value in
the context and appear as this in the input file. As the Mustache templating cannot extract those,
values that might be present, have an associated context, prefixed with @has_@. For example the
context @restart@ might not always be available, but this can be checked with the corresponding
@has_restart@ context.

The following context is provided (@Maybe@ declares contexts, which might not have an actual value
and will apear as @Nothing@ in Mustache and can be checked with the corresponding @has_@.):

  - @molecule@: program specific representation of the molecule (most often cartesian in angstrom).
  - @task@: a task string to tell the program which quantity to calculate.
  - @doEnergy@: boolean, that tells if an energy calculation shall be performed. Also true for
    hessian and gradient calculations.
  - @doGradient@: boolean, that tells if a gradient calculation shall be performed.
  - @doHessian@: boolean, that tells if a hessian calculation shall be perfomed.
  - @charge@: @Maybe@ the molecular charge. (@has_charge@)
  - @multiplicity@: @Maybe@ the spin multiplicity of the system. (@has_multiplicity@)
  - @openshells@: @Maybe@ the number of open MO shells in an unrestricted calculations.
    (@has_nopenshells@)
  - @prefix@: Is a name prefix somehow labeling the calculation. This is usually set by Spicy.
  - @permanent@: A path to a directory where permanent files can be written to. Files that go there
    should be allowed to be written to a shared network file system.
  - @scratch@: A path to a directory where scratch files can be written to.
  - @nprocs@: Number of distributet MPI/DDI/... processes to start.
  - @nthreads@: Number of threads __per__ process.
  - @memory@: Memory assigned to the program in MiB.
  - @restart@: @Maybe@ a path to the restart file. (@has_restart@)

See `goldentests/input` for some examples:

- **Psi4:** The calculation is expected to at least produce a formatted checkpoint file with the
  name `{{ prefix }}.fchk`. Hessian information need to be saved by numpy as plain text array, as
  they don't make it to the FChk for some reason in Psi4.
-}
translate2Input
  :: MonadThrow m
  => Molecule     -- ^ The complete molecule construct from top level on.
  -> CalcID       -- ^ The ID of the calculation to perform on the molecule.
  -> m Text       -- ^ Processed template.
translate2Input mol calcID = do
  -- Get the appropiate molecule layer and calculation context.
  (calcContext, molContext) <- getCalcByID mol calcID

  let -- Generat the context for Mustache.
    calcInput          = calcContext ^. calcContext_Input
    program'           = calcInput ^. calcInput_Software
    task'              = calcInput ^. calcInput_Task
    multiplicity       = calcInput ^? calcInput_QMMMSpec . _QM . qmContext_Mult
    charge'            = calcInput ^? calcInput_QMMMSpec . _QM . qmContext_Charge
    contextCharge      = maybeContext charge'
    contextHasCharge   = isJust charge'
    contextMult        = maybeContext multiplicity
    contextHasMult     = isJust multiplicity
    nOShells           = (\x -> x - 1) <$> multiplicity
    contextNOShells    = maybeContext nOShells
    contextHasNOShells = isJust nOShells
    contextPrefix      = Text.pack $ calcInput ^. calcInput_PrefixName
    contextPermaDir    = Text.pack . Path.toString . getDirPathAbs $ calcInput ^. calcInput_PermaDir
    contextScratchDir =
      Text.pack . Path.toString . getDirPathAbs $ calcInput ^. calcInput_ScratchDir
    contextNProcs     = calcInput ^. calcInput_NProcs
    contextNThreads   = calcInput ^. calcInput_NThreads
    contextMemory     = calcInput ^. calcInput_Memory
    restart = Text.pack . Path.toString . getFilePathAbs <$> calcInput ^. calcInput_RestartFile
    contextRestart    = maybeContext restart
    contextHasRestart = isJust restart
    contextDoEnergy   = case task' of
      WTEnergy   -> True
      WTGradient -> True
      WTHessian  -> True
    contextDoGradient = case task' of
      WTGradient -> True
      _          -> False
    contextDoHessian = case task' of
      WTHessian -> True
      _         -> False
  contextMolecule <- toMolRepr molContext program'
  contextTask     <- toTask task' program'
  let context = object
        [ "molecule" .= contextMolecule
        , "task" .= contextTask
        , "doEnergy" .= contextDoEnergy
        , "doGradient" .= contextDoGradient
        , "doHessian" .= contextDoHessian
        , "charge" .= contextCharge
        , "has_charge" .= contextHasCharge
        , "multiplicity" .= contextMult
        , "has_multiplicity" .= contextHasMult
        , "nopenshells" .= contextNOShells
        , "has_nopenshells" .= contextHasNOShells
        , "prefix" .= contextPrefix
        , "permanent" .= contextPermaDir
        , "scratch" .= contextScratchDir
        , "nprocs" .= contextNProcs
        , "nthreads" .= contextNThreads
        , "memory" .= contextMemory
        , "restart" .= contextRestart
        , "has_restart" .= contextHasRestart
        ]

  -- Parse the Ginger template.
  let template       = calcInput ^. calcInput_Template
      parsedTemplate = compileMustacheText
        (PName $ tShow program' <> " template for CalcID" <> tShow calcID)
        template

  -- Render the Mustache document with context.
  let mustacheResultWithWarnings = flip renderMustacheW context <$> parsedTemplate

  case mustacheResultWithWarnings of
    Left err ->
      throwM
        . WrapperGenericException "translate2Input"
        $ (  "Could not parse the mustache template for CalcID "
          <> show calcID
          <> " with: "
          <> show err
          <> "."
          )
    Right (_warnings, mustacheResult) -> return . Text.toStrict $ mustacheResult
 where
  maybeContext :: Show a => Maybe a -> Text
  maybeContext a = fromMaybe "Nothing" $ tShow <$> a

----------------------------------------------------------------------------------------------------
{-|
This gives a 'Molecule' in the program specific representation for a wrapper calculation.
-}
-- TODO (phillip|p=100|#Wrong) - This works only if no multipoles are inherited. The writers here are not aware of dummy types and how to insert multipoles.
toMolRepr
  :: MonadThrow m
  => Molecule  -- ^ The __current__ 'Molecule' layer for which to perform the calculation.
  -> Program   -- ^ The 'Program' for which the representation shall be generated.
  -> m Text    -- ^ Molecule representation inf the program format.
toMolRepr mol program'
  | program' == Psi4 = simpleCartesianAngstrom
  | program' == Nwchem = simpleCartesianAngstrom
  | otherwise = throwM
  $ WrapperGenericException "toMolRepr" "Cannot write a molecule format for this software."
  where simpleCartesianAngstrom = Text.unlines . drop 2 . Text.lines <$> writeXYZ mol

----------------------------------------------------------------------------------------------------
{-|
Generates a "task" string specific for computational chemistry 'Program'.
-}
toTask :: MonadThrow m => WrapperTask -> Program -> m Text
toTask task' program'
  | program' == Psi4 = psi4Task
  | otherwise = throwM
  $ WrapperGenericException "toTask" "Cannot create a task string for the chosen software."
 where
  psi4Task = case task' of
    WTEnergy   -> return "energy"
    WTGradient -> return "gradient"
    WTHessian  -> return "hessian"