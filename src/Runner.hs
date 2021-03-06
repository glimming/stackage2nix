module Runner ( run ) where

import Control.Lens
import Data.Foldable as F
import Data.List as L
import Distribution.Nixpkgs.Haskell.FromStack
import Distribution.Nixpkgs.Haskell.FromStack.Package
import Distribution.Nixpkgs.Haskell.Stack
import Distribution.Nixpkgs.Haskell.Stack.PrettyPrinting as PP
import Distribution.Version (Version)
import Distribution.Compiler (AbiTag(..), unknownCompilerInfo)
import Distribution.Package (mkPackageName, pkgName)
import Distribution.Text as Text (display)
import Language.Nix as Nix
import Options.Applicative
import Paths_stackage2nix ( version )
import Runner.Cli
import Stack.Config
import Stack.Types
import Stackage.Types
import System.IO (withFile, IOMode(..), hPutStrLn)
import Text.PrettyPrint.HughesPJClass (Doc, render)

import qualified Data.Set as Set
import qualified Data.Map as Map
import qualified LtsHaskell as LH


run :: IO ()
run = do
  opts <- execParser pinfo
  case opts ^. optConfigOrigin of
    -- Generate build derivation from stack.yaml file
    OriginStackYaml stackYaml -> do
      stackConf <- either fail pure =<< readStackConfig stackYaml
      let buildPlanFile = LH.buildPlanFilePath (opts ^. optLtsHaskellRepo) (stackConf ^. scResolver)
      buildPlan <- LH.loadBuildPlan buildPlanFile
      packageSetConfig <- LH.buildPackageSetConfig
        (opts ^. optHackageDb)
        (opts ^. optAllCabalHashesRepo)
        (opts ^. optNixpkgsRepository)
        buildPlan
      let
        overrideConfig = mkOverrideConfig opts (siGhcVersion $ bpSystemInfo buildPlan)
        stackPackagesConfig = mkStackPackagesConfig opts
      stackConfPackages <- traverse (packageDerivation stackPackagesConfig (opts ^. optHackageDb))
        $ stackConf ^. scPackages
      let
        reachable = Set.map mkPackageName
          $ F.foldr1 Set.union
          $ nodeDepends . mkNode <$> stackConfPackages
        s2nLoader mHash pkgId =
          if pkgName pkgId `Set.member` reachable
          then packageLoader packageSetConfig Nothing pkgId
          else packageLoader packageSetConfig mHash pkgId
        s2nPackageSetConfig = packageSetConfig { packageLoader = s2nLoader }
        s2nPackageConfig = PackageConfig
          { enableCheck     = opts ^. optDoCheckStackage
          , enableHaddock   = opts ^. optDoHaddockStackage }
      stackagePackages <- traverse (uncurry (buildNode s2nPackageSetConfig s2nPackageConfig))
        $ Map.toAscList (bpPackages buildPlan)

      let
        -- Nixpkgs generic-builder puts hscolour on path for all libraries
        withHscolour pkgs =
          let hscolour = F.find ((== "hscolour") . nodeName) stackagePackages
          in maybe pkgs (`Set.insert` pkgs) hscolour
        -- Find all reachable dependencies in stackage set to stick into
        -- stackage packages file. This is performed on the full stackage
        -- set rather than pruning stackage packages beforehand because
        -- stackage does not concern itself with build tools while cabal2nix
        -- does: pruning only after generating full set of packages allows
        -- us to make sure all those extra dependencies are explicitly
        -- listed as well.
        nodes = case opts ^. optOutPackagesClosure of
          True -> Set.toAscList
            $ withHscolour
            $ flip reachableDependencies stackagePackages
            -- Originally reachable nodes are root nodes
            $ L.filter (\n -> mkPackageName (nodeName n) `Set.member` reachable) stackagePackages
          False -> stackagePackages
      writeOutFile buildPlanFile (opts ^. optOutStackagePackages)
        $ pPrintOutPackages (view nodeDerivation <$> nodes)
      writeOutFile buildPlanFile (opts ^. optOutStackageConfig)
        $ pPrintOutConfig (bpSystemInfo buildPlan) nodes
      writeOutFile (stackYaml ^. syFilePath) (opts ^. optOutDerivation)
        $ PP.overrideHaskellPackages overrideConfig stackConfPackages

    -- Generate Stackage packages from resolver
    OriginResolver stackResolver -> do
      let
        buildPlanFile = LH.buildPlanFilePath (opts ^. optLtsHaskellRepo) stackResolver
        packageConfig = PackageConfig
          { enableCheck     = True
          , enableHaddock   = True }
      buildPlan <- LH.loadBuildPlan buildPlanFile
      packageSetConfig <- LH.buildPackageSetConfig
        (opts ^. optHackageDb)
        (opts ^. optAllCabalHashesRepo)
        (opts ^. optNixpkgsRepository)
        buildPlan
      nodes <- traverse (uncurry (buildNode packageSetConfig packageConfig))
        $ Map.toAscList (bpPackages buildPlan)
      let overrideConfig = mkOverrideConfig opts (siGhcVersion $ bpSystemInfo buildPlan)

      writeOutFile buildPlanFile (opts ^. optOutStackagePackages)
        $ pPrintOutPackages (view nodeDerivation <$> nodes)
      writeOutFile buildPlanFile (opts ^. optOutStackageConfig)
        $ pPrintOutConfig (bpSystemInfo buildPlan) nodes
      writeOutFile buildPlanFile (opts ^. optOutDerivation)
        $ PP.pPrintHaskellPackages overrideConfig

writeOutFile :: Show source => source -> FilePath -> Doc -> IO ()
writeOutFile source filePath contents =
  withFile filePath WriteMode $ \h -> do
    hPutStrLn h ("# Generated by stackage2nix " ++ Text.display version ++ " from " ++ show source)
    hPutStrLn h $ render contents

mkOverrideConfig :: Options -> Version -> OverrideConfig
mkOverrideConfig opts ghcVersion = OverrideConfig
  { _ocGhc              = ghcVersion
  , _ocStackagePackages = opts ^. optOutStackagePackages
  , _ocStackageConfig   = opts ^. optOutStackageConfig
  , _ocNixpkgs          = opts ^. optNixpkgsRepository }

mkStackPackagesConfig :: Options -> StackPackagesConfig
mkStackPackagesConfig opts = StackPackagesConfig
  { _spcHaskellResolver   = const True
  , _spcNixpkgsResolver   = \i -> Just (Nix.binding # (i, Nix.path # [i]))
  , _spcTargetPlatform    = opts ^. optPlatform
  , _spcTargetCompiler    = unknownCompilerInfo (opts ^. optCompilerId) NoAbiTag
  , _spcFlagAssignment    = []
  , _spcDoCheckPackages   = opts ^. optDoCheckPackages
  , _spcDoHaddockPackages = opts ^. optDoHaddockPackages
  , _spcDoCheckStackage   = opts ^. optDoCheckStackage
  , _spcDoHaddockStackage = opts ^. optDoHaddockStackage }
