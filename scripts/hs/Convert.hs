-- Copyright (C) 2026 Andrei Errapart
-- SPDX-License-Identifier: GPL-2.0-or-later

-- | The pure conversion core: turn raw `.DSN` bytes (OLE compound document or
-- a ZIP-of-streams synthetic fixture) into the KiCad project's files, all in
-- memory.  No disk I/O here -- that split is what makes the browser/WASM path
-- possible and keeps this module independent of how the program was invoked.
module Convert (ConvertOptions(..), convertDsnBytes) where

import Binary (unlessEither, lookupList)
import Container (parseOleStreams, parseStoredZip, isZipArchive, ZipMember(..))
import qualified Data.ByteString as BS
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import qualified Data.Set as Set
import Dsn.Cache (parseCacheSymbols)
import Dsn.Library
  ( libraryRawStrings, libraryFaceNameBytes
  , parseLibraryValueStrings, parseLibraryTextStyles
  )
import Dsn.Page (parsePage, pageStreamPath)
import Encoding (SourceEncoding, detectSourceEncoding)
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

-- | The rendering-relevant options: everything the pure conversion needs,
-- separated from the CLI record (paths, output directory) that only `Main`
-- cares about.
data ConvertOptions = ConvertOptions
  { convertProjectName :: String
  , convertSourceEncoding :: Maybe SourceEncoding
  , convertEmitWorksheet :: Bool
  , convertRender :: RenderConfig
  }

-- | Convert a .DSN from raw bytes, sniffing the container.  Pure: the whole
-- project comes back as {filename: contents}, which is what makes the
-- browser and WASM paths possible.
convertDsnBytes
  :: ConvertOptions -> BS.ByteString -> Either String [(FilePath, String)]
convertDsnBytes opts bytes
  | isZipArchive bytes = convertZipBytes opts bytes
  | otherwise = convertOleBytes opts bytes

convertZipBytes :: ConvertOptions -> BS.ByteString -> Either String [(FilePath, String)]
convertZipBytes opts bytes = do
  members <- parseStoredZip bytes
  convertStreams opts bytes [(name, body) | ZipMember name body <- members]

convertOleBytes :: ConvertOptions -> BS.ByteString -> Either String [(FilePath, String)]
convertOleBytes opts bytes = do
  streams <- parseOleStreams bytes
  convertStreams opts bytes streams

convertStreams
  :: ConvertOptions
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
        (convertSourceEncoding opts)
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
      project = convertProjectName opts
      pageCount = length pages
      dsnDigest = sha256 sourceBytes
      renderConfig = convertRender opts
      pageFiles =
        [ (pageOutputName page, generatePageSch
            dsnDigest renderConfig project cacheSymbols multiUnits powerRefs
            textStyles pageIndex pageCount page)
        | (pageIndex, page) <- zip [1..] pages
        ]
      worksheetFiles =
        [ (project ++ ".kicad_wks", generateWorksheet)
        | convertEmitWorksheet opts
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
       , (project ++ ".kicad_pro", generateProject project (convertEmitWorksheet opts))
       , ("sym-lib-table", generateSymLibTable project)
       ]
    ++ worksheetFiles

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
