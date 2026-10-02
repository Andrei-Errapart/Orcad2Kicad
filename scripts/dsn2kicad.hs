{-# LANGUAGE ScopedTypeVariables #-}

-- Copyright (C) 2026 Andrei Errapart
-- SPDX-License-Identifier: GPL-2.0-or-later

-- Entry point.  Not directly executable: with the converter split across
-- modules GHC needs -i, which a shebang cannot supply.  Use scripts/dsn2kicad.
module Main (main) where

import Container (isZipArchive)
import Control.Monad (forM_, unless)
import Convert (ConvertOptions(..), convertDsnBytes)
import qualified Data.ByteString as BS
import Data.List
  ( intercalate
  , isPrefixOf
  )
import Encoding
  ( sourceEncodingByName, sourceEncodingNames
  , encodingFlagPrefix
  )
import Model (RenderConfig(..))
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

data CliOptions = CliOptions
  { cliDsnPath :: FilePath
  , cliOutputDir :: FilePath
  , cliConvert :: ConvertOptions
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
      exists <- doesFileExist (cliDsnPath opts)
      unless exists $ do
        hPutStrLn stderr ("DSN not found: " ++ cliDsnPath opts)
        exitWith (ExitFailure 1)

      dsnBytes <- BS.readFile (cliDsnPath opts)
      let container = if isZipArchive dsnBytes then "ZIP" else "OLE"
      case convertDsnBytes (cliConvert opts) dsnBytes of
        Right files -> writeOutput opts files
        Left err -> do
          hPutStrLn stderr $
            "dsn2kicad: native " ++ container ++ " conversion failed: " ++ err
          exitWith (ExitFailure 1)

parseOptions :: [String] -> Either String CliOptions
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
      makeOptions encoding dsn outDir = CliOptions
        { cliDsnPath = dsn
        , cliOutputDir = outDir
        , cliConvert = ConvertOptions
            { convertProjectName = takeBaseName dsn
            , convertSourceEncoding = encoding
            , convertEmitWorksheet = "--no-worksheet" `notElem` flags
            , convertRender = RenderConfig
                { useKicadPower = "--kicad-power" `elem` flags
                , useKicadRc = "--kicad-rc" `elem` flags
                , useKicadFonts = "--kicad-fonts" `elem` flags
                }
            }
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
          [dsn] ->
            Right (makeOptions encoding dsn (takeBaseName dsn ++ "_kicad"))
          dsn : outDir : extra ->
            if null extra
              then Right (makeOptions encoding dsn outDir)
              else Left ("Unexpected extra arguments: " ++ unwords extra)

partitionArgs :: [String] -> ([String], [String])
partitionArgs = go [] []
  where
    -- Stop flag parsing at "--" and treat all following arguments as positional,
    -- even if they start with "--".
    go flags positional [] = (reverse flags, reverse positional)
    go flags positional (arg:rest)
      | arg == "--" = (reverse flags, reverse positional ++ rest)
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

-- KiCad files are UTF-8 whatever the host locale is.  `writeFile` encodes
-- through the locale's TextEncoding instead, so the bytes on disk would vary
-- with the environment, and under a non-UTF-8 locale (glibc `LC_ALL=C` yields
-- ASCII, the default in many CI and container images) it aborts the run at
-- write time with "commitBuffer: invalid argument".  Encoding here makes the
-- output byte-identical everywhere and keeps the write path free of Handle
-- encoding state -- which the intended WASM build needs anyway.
writeOutput :: CliOptions -> [(FilePath, String)] -> IO ()
writeOutput opts files = do
  putStrLn ("Opening " ++ takeFileName (cliDsnPath opts) ++ "...")
  createDirectoryIfMissing True (cliOutputDir opts)
  forM_ files $ \(name, content) ->
    BS.writeFile (cliOutputDir opts </> name) (utf8Encode content)
  putStrLn ("Done -> " ++ cliOutputDir opts ++ "/")
