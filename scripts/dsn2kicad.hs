{-# LANGUAGE ScopedTypeVariables #-}

-- Copyright (C) 2026 Andrei Errapart
-- SPDX-License-Identifier: GPL-2.0-or-later

-- Entry point.  Not directly executable: with the converter split across
-- modules GHC needs -i, which a shebang cannot supply.  Use scripts/dsn2kicad.
module Main (main) where

import Binary (unlessEither, lookupList)
import Container (parseOleStreams, parseStoredZip, isZipArchive, ZipMember(..))
import Control.Monad (forM_, unless)
import qualified Data.ByteString as BS
import Data.List
  ( intercalate
  , isPrefixOf
  , sortOn
  )
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import qualified Data.Set as Set
import Dsn.Cache (parseCacheSymbols)
import Dsn.Library
  ( libraryRawStrings, libraryFaceNameBytes
  , parseLibraryValueStrings, parseLibraryTextStyles
  )
import Dsn.Page (parsePage, pageStreamPath)
import Encoding
  ( SourceEncoding, sourceEncodingByName, sourceEncodingNames
  , encodingFlagPrefix, detectSourceEncoding
  )
import Emit.Page (generatePageSch)
import Emit.Project
  ( generateRootSch, generateProject, generateSymLibTable, generateWorksheet
  )
import Emit.Symbol (generateSymbolLibrary)
import Model
  ( Page(..), Component(..), PagePin(..), Pin(..)
  , CacheSymbol(..)
  , RenderConfig(..)
  , detectMultiUnitComponents, assignPowerReferences
  , canonicalizePageNetNames, disambiguatePageOutputName
  )
import Orcad.Geometry (forwardOrcadPoint, symbolOrigin)
import Sha256 (sha256)
import System.Directory
  ( createDirectoryIfMissing
  , doesFileExist
  )
import System.Environment (getArgs)
import System.Exit (ExitCode(..), exitWith)
import System.FilePath
  ( (</>)
  , takeBaseName
  , takeFileName
  )
import System.IO (hPutStrLn, hSetEncoding, stderr, stdout, utf8)
import Utf8 (utf8Encode)

data Options = Options
  { optDsnPath :: FilePath
  , optOutputDir :: FilePath
  , optProjectName :: String
  , optKicadPower :: Bool
  , optKicadRc :: Bool
  , optKicadFonts :: Bool
  , optEmitWorksheet :: Bool
  , optSourceEncoding :: Maybe SourceEncoding
  }

renderConfigOf :: Options -> RenderConfig
renderConfigOf opts = RenderConfig
  { useKicadPower = optKicadPower opts
  , useKicadRc = optKicadRc opts
  , useKicadFonts = optKicadFonts opts
  }

main :: IO ()
main = do
  -- Diagnostics carry design-supplied text (paths, page names), so the
  -- message handles need an encoding that can represent it too.
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  rawArgs <- getArgs
  case parseOptions rawArgs of
    Left msg -> do
      hPutStrLn stderr msg
      usage
      exitWith (ExitFailure 1)
    Right opts -> do
      exists <- doesFileExist (optDsnPath opts)
      unless exists $ do
        hPutStrLn stderr ("DSN not found: " ++ optDsnPath opts)
        exitWith (ExitFailure 1)

      dsnBytes <- BS.readFile (optDsnPath opts)
      if isZipArchive dsnBytes
        then writeNativeOrExit "ZIP" opts (convertZipBytes opts dsnBytes)
        else writeNativeOrExit "OLE" opts (convertOleBytes opts dsnBytes)

writeNativeOrExit :: String -> Options -> Either String [(FilePath, String)] -> IO ()
writeNativeOrExit container opts result =
  case result of
    Right files -> writeOutput opts files
    Left err -> do
      hPutStrLn stderr $
        "dsn2kicad: native " ++ container ++ " conversion failed: " ++ err
      exitWith (ExitFailure 1)

parseOptions :: [String] -> Either String Options
parseOptions argv =
  let (flags, positional) = partitionArgs argv
      debugFlags = ["--debug-bbox", "--debug-ref-val", "--debug-symbol"]
      supportedFlags =
        [ "--kicad-power", "--kicad-rc", "--kicad-fonts", "--no-worksheet"
        , "--native-only"
        ]
      isEncodingFlag = (encodingFlagPrefix `isPrefixOf`)
      unknownFlags =
        [ f
        | f <- flags
        , f `notElem` (debugFlags ++ supportedFlags)
        , not (isEncodingFlag f)
        ]
      requestedDebugFlags = filter (`elem` debugFlags) flags
      encodingNames =
        [ drop (length encodingFlagPrefix) f | f <- flags, isEncodingFlag f ]
      makeOptions encoding dsn outDir = Options
        { optDsnPath = dsn
        , optOutputDir = outDir
        , optProjectName = takeBaseName dsn
        , optKicadPower = "--kicad-power" `elem` flags
        , optKicadRc = "--kicad-rc" `elem` flags
        , optKicadFonts = "--kicad-fonts" `elem` flags
        , optEmitWorksheet = "--no-worksheet" `notElem` flags
        , optSourceEncoding = encoding
        }
  in case unknownFlags of
    f : _ -> Left ("Unknown option: " ++ f)
    [] -> case requestedDebugFlags of
      f : _ -> Left $
        f ++ " is not implemented by scripts/dsn2kicad; "
        ++ "use scripts/dsn2kicad_py for debug overlays"
      [] -> do
        -- The last --source-encoding wins, matching how the boolean flags
        -- behave when repeated.
        encoding <- case reverse encodingNames of
          [] -> Right Nothing
          name : _ -> case sourceEncodingByName name of
            Just enc -> Right (Just enc)
            Nothing -> Left $
              "Unknown source encoding: " ++ name ++ " (known: "
              ++ intercalate ", " sourceEncodingNames ++ ")"
        case positional of
          [] -> Left "Missing DSN path"
          dsn : outDir : _ ->
            Right (makeOptions encoding dsn outDir)
          [dsn] ->
            Right (makeOptions encoding dsn (takeBaseName dsn ++ "_kicad"))

partitionArgs :: [String] -> ([String], [String])
partitionArgs = go [] []
  where
    go flags positional [] = (reverse flags, reverse positional)
    go flags positional (arg:rest)
      | "--" `isPrefixOf` arg = go (arg:flags) positional rest
      | otherwise = go flags (arg:positional) rest

usage :: IO ()
usage = do
  hPutStrLn stderr $
    "Usage: scripts/dsn2kicad [--kicad-power] [--kicad-rc] "
    ++ "[--kicad-fonts] [--no-worksheet] [--source-encoding=NAME] "
    ++ "<file.DSN> [output_dir]"
  hPutStrLn stderr $
    "--source-encoding overrides the detected Library codepage; known names: "
    ++ intercalate ", " sourceEncodingNames
  hPutStrLn stderr $
    "Debug flags are implemented by scripts/dsn2kicad_py only."

convertZipBytes :: Options -> BS.ByteString -> Either String [(FilePath, String)]
convertZipBytes opts bytes = do
  members <- parseStoredZip bytes
  convertStreams opts bytes [(name, body) | ZipMember name body <- members]

convertOleBytes :: Options -> BS.ByteString -> Either String [(FilePath, String)]
convertOleBytes opts bytes = do
  streams <- parseOleStreams bytes
  convertStreams opts bytes streams

convertStreams
  :: Options
  -> BS.ByteString
  -> [(FilePath, BS.ByteString)]
  -> Either String [(FilePath, String)]
convertStreams opts sourceBytes members = do
  let memberMap = Map.fromList members
      libraryBody = Map.lookup "Library" memberMap
      pageMembers =
        sortOn (\(viewName, pageName, _, _) -> (viewName, pageName))
          [ (viewName, pageName, name, body)
          | (name, body) <- members
          , Just (viewName, pageName) <- [pageStreamPath name]
          ]
      cacheSymbols = maybe Map.empty parseCacheSymbols (Map.lookup "Cache" memberMap)
      sourceEncoding = detectSourceEncoding
        (optSourceEncoding opts)
        (maybe [] libraryRawStrings libraryBody)
        (maybe [] libraryFaceNameBytes libraryBody)
      libraryValues =
        maybe [] (parseLibraryValueStrings sourceEncoding) libraryBody
      rawPages = canonicalizePageNetNames
        [parsePage libraryValues name body | (_, _, name, body) <- pageMembers]
      refinedPages = map (refinePageComponents cacheSymbols) rawPages
      pages = map (disambiguatePageOutputName project) refinedPages
      textStyles = maybe [] parseLibraryTextStyles libraryBody
      multiUnits = detectMultiUnitComponents pages
      powerRefs = assignPowerReferences pages
      project = optProjectName opts
      pageCount = length pages
      dsnDigest = sha256 sourceBytes
      renderConfig = renderConfigOf opts
      pageFiles =
        [ (pageOutputName page, generatePageSch
            dsnDigest renderConfig project cacheSymbols multiUnits powerRefs
            textStyles pageIndex pageCount page)
        | (pageIndex, page) <- zip [1..] pages
        ]
      worksheetFiles =
        [ (project ++ ".kicad_wks", generateWorksheet)
        | optEmitWorksheet opts
        ]
      outputNames = map pageOutputName pages
      rootFilename = project ++ ".kicad_sch"
  unlessEither (not (null pageMembers)) $
    "no schematic page streams found under Views/<view>/Pages/<page>"
  unlessEither (length outputNames == Set.size (Set.fromList outputNames)) $
    "multiple schematic pages map to the same KiCad output filename"
  pure $
    pageFiles
    ++ [ ( rootFilename
         , generateRootSch
             dsnDigest project pages
         )
       , (project ++ ".kicad_sym", generateSymbolLibrary renderConfig cacheSymbols multiUnits pages)
       , (project ++ ".kicad_pro", generateProject project (optEmitWorksheet opts))
       , ("sym-lib-table", generateSymLibTable project)
       ]
    ++ worksheetFiles

-- KiCad files are UTF-8 whatever the host locale is.  `writeFile` encodes
-- through the locale's TextEncoding instead, so the bytes on disk would vary
-- with the environment, and under a non-UTF-8 locale (glibc `LC_ALL=C` yields
-- ASCII, the default in many CI and container images) it aborts the run at
-- write time with "commitBuffer: invalid argument".  Encoding here makes the
-- output byte-identical everywhere and keeps the write path free of Handle
-- encoding state -- which the intended WASM build needs anyway.
writeOutput :: Options -> [(FilePath, String)] -> IO ()
writeOutput opts files = do
  putStrLn ("Opening " ++ takeFileName (optDsnPath opts) ++ "...")
  createDirectoryIfMissing True (optOutputDir opts)
  forM_ files $ \(name, content) ->
    BS.writeFile (optOutputDir opts </> name) (utf8Encode content)
  putStrLn ("Done -> " ++ optOutputDir opts ++ "/")

refinePageComponents :: Map.Map String CacheSymbol -> Page -> Page
refinePageComponents cacheSymbols page = page
  { pageComponents = map refine (pageComponents page)
  }
  where
    refine component =
      case Map.lookup (compCell component) cacheSymbols of
        Nothing -> component
        Just symbol ->
          let pins = cachePins symbol
              center = symbolOrigin symbol
              originsFor orient = mapMaybe (pinOrigin orient pins center)
                (compPagePins component)
              candidates =
                [ (orient, originsFor orient)
                | orient <- [0..7]
                , orient /= compOrient component
                ]
              (bestOrient, origins) = foldl chooseOrientation
                (compOrient component, originsFor (compOrient component)) candidates
          in if null origins || originSpread origins > 2
               then component
               else
                 let (originX, originY) = meanPoint origins
                     (centerX, centerY) = forwardOrcadPoint
                       center (compOrient component) center
                 in component
                   { compX = round (originX + centerX)
                   , compY = round (originY + centerY)
                   , compOrient = bestOrient
                   , compOriginX = Just originX
                   , compOriginY = Just originY
                   }

    pinOrigin orient pins center pagePin = do
      cachePin <- lookupList pins (pagePinNumber pagePin - 1)
      let (hotX, hotY) = forwardOrcadPoint
            (fromIntegral (pinHotX cachePin), fromIntegral (pinHotY cachePin))
            orient
            center
      pure
        ( fromIntegral (pagePinX pagePin) - hotX
        , fromIntegral (pagePinY pagePin) - hotY
        )

    chooseOrientation current@(_, currentOrigins) candidate@(_, candidateOrigins)
      | null candidateOrigins = current
      | null currentOrigins = candidate
      | originSpread candidateOrigins < originSpread currentOrigins = candidate
      | otherwise = current

    originSpread points =
      let xs = map fst points
          ys = map snd points
      in max (maximum xs - minimum xs) (maximum ys - minimum ys)

    meanPoint points =
      let count = fromIntegral (length points)
      in (sum (map fst points) / count, sum (map snd points) / count)
