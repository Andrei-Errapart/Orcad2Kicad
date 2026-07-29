{-# LANGUAGE ScopedTypeVariables #-}

-- Copyright (C) 2026 Andrei Errapart
-- SPDX-License-Identifier: GPL-2.0-or-later

-- Entry point.  Not directly executable: with the converter split across
-- modules GHC needs -i, which a shebang cannot supply.  Use scripts/dsn2kicad.
module Main (main) where

import Binary (unlessEither, lookupList, unique)
import Container (parseOleStreams, parseStoredZip, isZipArchive, ZipMember(..))
import Control.Monad (forM_, unless)
import Data.Bits ((.&.))
import qualified Data.ByteString as BS
import Data.Char (toUpper)
import Data.List
  ( intercalate
  , isPrefixOf
  , isSuffixOf
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
import Model
  ( Page(..), Wire(..), NetLabel(..), OffPageConnector(..)
  , Component(..), PagePin(..)
  , PowerStyle(..), PowerSymbol(..), Rgba(..)
  , PageText(..), GraphicStyle(..), PageGraphic(..)
  , TextStyle(..), TitleBlock(..)
  , Pin(..), Rect(..), Segment(..), Ellipse(..), ArcShape(..)
  , Polygon(..), Polyline(..), TextAnnotation(..)
  , CacheSymbol(..), MultiUnitRegistry(..)
  , RenderConfig(..)
  , emptyCacheSymbol
  , componentUnitInfo, componentLibName, powerReferenceName
  , pinElectricalType, symbolPinVisibility
  , detectMultiUnitComponents, assignPowerReferences
  , canonicalizePageNetNames, disambiguatePageOutputName
  )
import Orcad.Geometry
  ( unitToMm
  , wirePoint1, wirePoint2, pointOnWire
  , computeJunctions, placeWireLabels
  , BusEntry(..), synthesizeBusEntries, explicitAliasCovers
  , forwardOrcadPoint, symbolOrigin, symbolPinsForOutput
  , directionFromVector, ellipsePoints, arcMidpoint, arcPoints
  , componentAngleFor
  , standardDevicePinPoint
  , powerSymbolAngle, powerValueAngle
  )
import Sexpr
  ( KExpr(..)
  , kAtom, kString, kNode, kInt, kDouble, kRawNum
  , kNo, kYes, kAt, kUuid, kCoord, kXy
  , kStroke, kFillType, kPolylineShape, kCircleShape, kArcShape
  , kTextEffects, kStyledTextEffects, kStyledProperty
  , kColoredStroke, kPageFill, kProperty, kHiddenProperty
  , renderKicad, esc, escJson
  )
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
import Text.Layout
  ( defaultComponentTextStyle, textStyleForId, normalizedTextRotation
  , nonEmptyTextLines, pageTextSize, pageTextLinePosition
  , componentFieldPlacement, powerValueCenter
  , orcadOverlineToKicad
  )
import Utf8 (utf8Encode)
import Uuid (deterministicUuid, stableObjectUuid)

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

generatePageSch
  :: BS.ByteString
  -> RenderConfig
  -> String
  -> Map.Map String CacheSymbol
  -> MultiUnitRegistry
  -> Map.Map (FilePath, Int) String
  -> [TextStyle]
  -> Int
  -> Int
  -> Page
  -> String
generatePageSch uuidSeed cfg _project cacheSymbols multiUnits powerRefs textStyles pageIndex pageCount page =
  renderKicad $
    kNode "kicad_sch" $
      [ kNode "version" [kInt 20260306]
      , kNode "generator" [kString "dsn2kicad"]
      , kNode "generator_version" [kString "0.1"]
      , kUuid (pageObjectUuid uuidSeed page 0 1)
      , kNode "paper" [kString (pagePaper page)]
      , emitTitleBlock
      , kNode "lib_symbols"
          (emitSymbolDefinitions cfg cacheSymbols multiUnits
            (pageComponents page) (pagePowerSymbols page))
      ]
      ++ zipWith emitWire [1..] regularWires
      ++ zipWith emitRcBridge [1..] rcBridgePairs
      ++ zipWith emitBus [1..] busWires
      ++ zipWith emitBusEntry [1..] busEntries
      ++ zipWith emitJunction [1..] junctions
      ++ zipWith emitNetLabel [1..] labels
      ++ zipWith emitComponent [1..] (pageComponents page)
      ++ zipWith emitPowerSymbol [1..] (pagePowerSymbols page)
      ++ zipWith emitPageGraphic [1..] (pageGraphics page)
      ++ concat (zipWith emitPageText [1..] (pageTexts page))
      ++ [ kNode "sheet_instances"
             [ kNode "path" [kString "/", kNode "page" [kString "1"]]
             ]
         , kNo "embedded_fonts"
         ]
  where
    titleBlock = pageTitleBlock page

    emitTitleBlock =
      kNode "title_block" $
        [kNode "title" [kString outputTitle]]
        ++ optional "date" (titleBlockDate titleBlock)
        ++ optional "rev" (titleBlockRevision titleBlock)
        ++ optional "company" (titleBlockCompany titleBlock)
        ++ [ kNode "comment"
               [kInt 1, kString (titleBlockDocumentNumber titleBlock)]
           | not (null (titleBlockDocumentNumber titleBlock))
           ]
        ++ [ kNode "comment"
               [ kInt 2
               , kString
                   ("Sheet " ++ show pageIndex ++ " of " ++ show pageCount)
               ]
           ]
      where
        optional name value = [kNode name [kString value] | not (null value)]

    outputTitle
      | null (titleBlockTitle titleBlock) = pageTitle page
      | otherwise = titleBlockTitle titleBlock

    (fieldSize, fieldFace, fieldBold, fieldItalic) =
      defaultComponentTextStyle (useKicadFonts cfg) textStyles

    emitWire wireIndex wire =
      let (x1, y1) = adjustedWirePoint wire (wireX1 wire, wireY1 wire)
          (x2, y2) = adjustedWirePoint wire (wireX2 wire, wireY2 wire)
      in
      kNode "wire"
        [ kNode "pts"
            [ kXy (fromIntegral x1 * unitToMm)
                  (fromIntegral y1 * unitToMm)
            , kXy (fromIntegral x2 * unitToMm)
                  (fromIntegral y2 * unitToMm)
            ]
        , kStroke "0.15" "default"
        , kUuid (pageObjectUuid uuidSeed page 1 wireIndex)
        ]

    adjustedWirePoint wire point =
      case Map.lookup point rcPinAdjustmentMap of
        Just newPoint
          | wireEndpointCanMove wire point newPoint -> newPoint
        _ -> Map.findWithDefault point point nativePinAdjustmentMap

    emitBus busIndex wire =
      kNode "bus"
        [ kNode "pts"
            [ kXy (fromIntegral (wireX1 wire) * unitToMm)
                  (fromIntegral (wireY1 wire) * unitToMm)
            , kXy (fromIntegral (wireX2 wire) * unitToMm)
                  (fromIntegral (wireY2 wire) * unitToMm)
            ]
        , kStroke "0" "default"
        , kUuid (pageObjectUuid uuidSeed page 12 busIndex)
        ]

    emitBusEntry entryIndex (BusEntry x y dx dy) =
      kNode "bus_entry"
        [ kAt [kCoord x, kCoord y]
        , kNode "size" [kCoord dx, kCoord dy]
        , kStroke "0" "default"
        , kUuid (pageObjectUuid uuidSeed page 13 entryIndex)
        ]

    regularWires =
      [ wire
      | wire <- pageWires page
      , not (wireIsBus wire)
      , not (Set.member (orderedWirePoints wire) rcInternalConnections)
      ]
    busWires = filter wireIsBus (pageWires page)
    nativePinAdjustments =
      [ (oldPoint, newPoint)
      | component <- pageComponents page
      , not (useKicadRc cfg && compCell component `elem` ["R", "C"])
      , Just symbol <- [Map.lookup (compCell component) cacheSymbols]
      , (oldPin, newPin) <- zip
          (cachePins symbol)
          (symbolPinsForOutput (compCell component) symbol)
      , let oldPoint = placedPinPoint component symbol oldPin
            newPoint = placedPinPoint component symbol newPin
      , oldPoint /= newPoint
      ]
    rcPinAdjustments = [(oldPoint, newPoint) | (_, oldPoint, newPoint) <- rcPinMoves]
    nativePinAdjustmentMap = Map.fromList nativePinAdjustments
    rcPinAdjustmentMap = Map.fromList rcPinAdjustments
    rcInternalConnections = Set.fromList
      [ orderPoints firstPoint secondPoint
      | component <- pageComponents page
      , useKicadRc cfg
      , compCell component `elem` ["R", "C"]
      , [firstPoint, secondPoint] <- [rcOriginalPinPoints component]
      ]
    orderedWirePoints wire = orderPoints (wirePoint1 wire) (wirePoint2 wire)
    orderPoints first second = if first <= second then (first, second) else (second, first)
    rcBridgePairs = unique
      [ (oldPoint, newPoint)
      | (reference, oldPoint, newPoint) <- rcPinMoves
      , Set.member oldPoint powerPositions
        || hasOtherPinAt reference oldPoint
        || any (wireKeepsOldPoint oldPoint newPoint) regularWires
        || any (\alias -> (netLabelX alias, netLabelY alias) == oldPoint)
             (pageNetAliases page)
      ]
    rcPinMoves =
      [ (compRef component, oldPoint, newPoint)
      | component <- pageComponents page
      , useKicadRc cfg
      , compCell component `elem` ["R", "C"]
      , (pinNumberText, oldPoint) <- zip ["1", "2"] (rcOriginalPinPoints component)
      , Just newPoint <- [standardDevicePinPoint component pinNumberText]
      , oldPoint /= newPoint
      ]
    rcOriginalPinPoints component =
      case Map.lookup (compCell component) cacheSymbols of
        Just symbol
          | [firstPin, secondPin] <- cachePins symbol ->
              map (placedPinPoint component symbol) [firstPin, secondPin]
        _ ->
          [ (pagePinX pin, pagePinY pin)
          | pin <- compPagePins component
          ]
    pinOwners =
      [ ((pagePinX pin, pagePinY pin), compRef component)
      | component <- pageComponents page
      , pin <- compPagePins component
      ]
      ++
      [ (placedPinPoint component symbol pin, compRef component)
      | component <- pageComponents page
      , Just symbol <- [Map.lookup (compCell component) cacheSymbols]
      , pin <- cachePins symbol
      ]
    hasOtherPinAt reference point = any
      (\(pinPoint, owner) -> pinPoint == point && owner /= reference)
      pinOwners
    wireEndpointCanMove wire oldPoint newPoint =
      let otherPoint = if oldPoint == wirePoint1 wire
            then wirePoint2 wire
            else wirePoint1 wire
          (moveX, moveY) = subtractPoint newPoint oldPoint
          (wireX, wireY) = subtractPoint otherPoint oldPoint
      in (oldPoint == wirePoint1 wire || oldPoint == wirePoint2 wire)
         && moveX * wireY == moveY * wireX
    wireKeepsOldPoint oldPoint newPoint wire
      | not (pointOnWire oldPoint wire) = False
      | oldPoint /= wirePoint1 wire && oldPoint /= wirePoint2 wire = True
      | otherwise = not (wireEndpointCanMove wire oldPoint newPoint)
    subtractPoint (x1, y1) (x2, y2) = (x1 - x2, y1 - y2)
    (busEntries, busEntryLandings) =
      synthesizeBusEntries busWires regularWires
    junctions = computeJunctions regularWires
    powerNets = Set.fromList
      [ powerNetName symbol
      | symbol <- pagePowerSymbols page
      , powerMatched symbol
      ]
    regularLabels =
      [ label
      | label <- placeWireLabels powerNets regularWires
      , let point = (netLabelX label, netLabelY label)
      , not (Set.member point pinPositions)
      , not (Set.member point powerPositions)
      , not (Set.member point offPagePositions)
      , netLabelGlobal label
        || not (explicitAliasCovers regularWires (pageNetAliases page) label)
      ]
    busLabels =
      [ label
      | label <- placeWireLabels Set.empty busWires
      , not (Set.member (netLabelX label, netLabelY label) busEntryLandings)
      , not (Set.member (netLabelX label, netLabelY label) offPagePositions)
      ]
    explicitAliases =
      [ alias
      | alias <- pageNetAliases page
      , not (Set.member (netLabelX alias, netLabelY alias) powerPositions)
      , not (Set.member (netLabelX alias, netLabelY alias) offPagePositions)
      ]
    -- OrCAD net aliases are page-local.  Cross-page signal scope is recorded
    -- by placed OFFPAGE symbols, while power-symbol instances carry global
    -- power scope.  A net-table name repeated on another page is not itself a
    -- scope marker.
    explicitOffPageLabels =
      [ NetLabel True (offPageNetName connector)
          (offPageX connector) (offPageY connector) (offPageAngle connector)
      | connector <- pageOffPageConnectors page
      , offPageMatched connector
      , not (null (offPageNetName connector))
      ]
    labels = unique
      (regularLabels ++ explicitAliases ++ busLabels ++ explicitOffPageLabels)
    offPagePositions = Set.fromList
      [ (offPageX connector, offPageY connector)
      | connector <- pageOffPageConnectors page
      , offPageMatched connector
      ]
    pinPositions = Set.fromList $
      [ (pagePinX pin, pagePinY pin)
      | component <- pageComponents page
      , pin <- compPagePins component
      ]
      ++
      [ placedPinPoint component symbol pin
      | component <- pageComponents page
      , Just symbol <- [Map.lookup (compCell component) cacheSymbols]
      , pin <- cachePins symbol
      ]
    powerPositions = Set.fromList
      [ (powerHotX symbol, powerHotY symbol)
      | symbol <- pagePowerSymbols page
      ]

    placedPinPoint component symbol pin =
      let center@(centerX, centerY) = symbolOrigin symbol
          (hotX, hotY) = forwardOrcadPoint
            (fromIntegral (pinHotX pin), fromIntegral (pinHotY pin))
            (compOrient component)
            center
      in ( round (fromIntegral (compX component) + hotX - centerX)
         , round (fromIntegral (compY component) + hotY - centerY)
         )

    emitJunction junctionIndex (x, y) =
      kNode "junction"
        [ kAt [kCoord x, kCoord y]
        , kNode "diameter" [kInt 0]
        , kNode "color" [kInt 0, kInt 0, kInt 0, kInt 0]
        , kUuid (pageObjectUuid uuidSeed page 5 junctionIndex)
        ]

    emitRcBridge bridgeIndex ((x1, y1), (x2, y2)) =
      kNode "wire"
        [ kNode "pts" [kXy (fromIntegral x1 * unitToMm) (fromIntegral y1 * unitToMm)
                       , kXy (fromIntegral x2 * unitToMm) (fromIntegral y2 * unitToMm)]
        , kStroke "0.15" "default"
        , kUuid (pageObjectUuid uuidSeed page 14 bridgeIndex)
        ]

    emitNetLabel labelIndex label
      | netLabelGlobal label = emitGlobalLabel labelIndex label
      | otherwise = emitLocalLabel labelIndex label

    emitLocalLabel labelIndex label =
      let angle = netLabelAngle label
          justify =
            if angle == 180 || angle == 270
              then [kAtom "right", kAtom "bottom"]
              else [kAtom "left", kAtom "bottom"]
      in kNode "label"
          [ kString (netLabelName label)
          , kAt [kCoord (netLabelX label), kCoord (netLabelY label), kInt angle]
          , kNode "effects"
              [ kNode "font"
                  [ kNode "size" [kRawNum "1.27", kRawNum "1.27"]
                  ]
              , kNode "justify" justify
              ]
          , kUuid (pageObjectUuid uuidSeed page 6 labelIndex)
          ]

    emitGlobalLabel labelIndex label =
      let angle = netLabelAngle label
          justify = if angle == 180 then kAtom "right" else kAtom "left"
      in kNode "global_label"
          [ kString (netLabelName label)
          , kNode "shape" [kAtom "bidirectional"]
          , kAt [kCoord (netLabelX label), kCoord (netLabelY label), kInt angle]
          , kNode "effects"
              [ kNode "font"
                  [ kNode "size" [kRawNum "1.27", kRawNum "1.27"]
                  ]
              , kNode "justify" [justify]
              ]
          , kUuid (pageObjectUuid uuidSeed page 7 labelIndex)
          , kNode "property"
              [ kString "Intersheetrefs"
              , kString "${INTERSHEET_REFS}"
              , kAt [kInt 0, kInt 0, kInt 0]
              , kNode "effects"
                  [ kNode "font"
                      [ kNode "size" [kRawNum "1.27", kRawNum "1.27"]
                      ]
                  , kYes "hide"
                  ]
              ]
          ]

    emitComponent compIndex comp =
      let symbol = Map.findWithDefault emptyCacheSymbol (compCell comp) cacheSymbols
          (_, unitNumber) = componentUnitInfo multiUnits (compCell comp)
          libName = componentLibName cfg multiUnits (compCell comp)
          pinNumbers = if useKicadRc cfg && compCell comp `elem` ["R", "C"]
            then ["1", "2"]
            else unique (map pinNumber (cachePins symbol))
          angle = componentAngleFor cfg comp
          dnp = " *DNP" `isSuffixOf` compValue comp
          value = if dnp
            then take (length (compValue comp) - length (" *DNP" :: String)) (compValue comp)
            else compValue comp
          mirrorFields = [kNode "mirror" [kAtom "y"] | compOrient comp .&. 0x04 /= 0]
          -- Placement anchor. When the body origin was recovered by pin
          -- matching, compX/compY already is that origin. A part with no
          -- usable pins (mounting screws, holes) has no pin-matched origin,
          -- and the raw cell position is not where OrCAD draws the body: the
          -- cell's local frame is anchored at the instance loc, so the body
          -- lands at loc + symbolOrigin -- symbolOrigin being the same
          -- graphics midpoint the emitted lib symbol is centred on. Checked
          -- against the OrCAD PDF vector geometry for SCR1 and SP1 on 0002.
          (placeX, placeY) = case compOriginX comp of
            Just _ -> (compX comp, compY comp)
            Nothing ->
              let (symOx, symOy) = symbolOrigin symbol
              in ( compLocX comp + round symOx
                 , compLocY comp + round symOy
                 )
          componentFields =
            [ kNode "lib_id" [kString libName]
            , kAt
                [ kCoord placeX
                , kCoord placeY
                , kInt angle
                ]
            ]
            ++ mirrorFields
            ++
            [ kNode "unit" [kInt unitNumber]
            , kNo "exclude_from_sim"
            , if dnp then kNo "in_bom" else kYes "in_bom"
            , kYes "on_board"
            , if dnp then kYes "dnp" else kNo "dnp"
            , kUuid (pageObjectUuid uuidSeed page 2 compIndex)
            , emitComponentProperty
                "Reference"
                (compRef comp)
                (compRefField comp)
                True
            , emitComponentProperty
                "Value"
                value
                (compValueField comp)
                False
            ]
          placedPins =
            zipWith
              (\pinIndex number ->
                kNode "pin"
                  [ kString number
                  , kUuid (pagePinUuid uuidSeed page compIndex pinIndex)
                  ])
              [1..]
              pinNumbers
          instances =
            kNode "instances"
              [ kNode "project"
                  [ kString ""
                  , kNode "path"
                      [ kString "/"
                      , kNode "reference" [kString (compRef comp)]
                      , kNode "unit" [kInt unitNumber]
                      ]
                  ]
              ]
      in kNode "symbol" (componentFields ++ placedPins ++ [instances])

      where
        emitComponentProperty propertyName value displayField isReference =
          let fallbackY = compY comp + if isReference then -10 else 10
              atExpr = case displayField of
                Just field ->
                  let (x, y, angle) = componentFieldPlacement cfg comp field
                        value fieldSize fieldFace fieldBold fieldItalic
                  in kAt [kDouble x, kDouble y, kInt angle]
                Nothing -> kAt [kCoord (compX comp), kCoord fallbackY, kInt 0]
          in kStyledProperty propertyName value atExpr
               fieldSize fieldFace fieldBold fieldItalic

    emitPowerSymbol powerIndex symbol =
      let x = powerHotX symbol
          y = powerHotY symbol
          reference = Map.findWithDefault
            (powerReferenceName powerIndex)
            (pageStreamName page, powerIndex)
            powerRefs
          fields =
            [ kNode "lib_id" [kString ("power:" ++ powerLibName cfg symbol)]
            , kAt [kCoord x, kCoord y, kInt (powerSymbolAngle symbol)]
            , kNode "unit" [kInt 1]
            , kNo "exclude_from_sim"
            , kYes "in_bom"
            , kYes "on_board"
            , kNo "dnp"
            , kUuid (pageObjectUuid uuidSeed page 8 powerIndex)
            , kHiddenProperty
                "Reference"
                reference
                (kAt [kCoord x, kCoord y, kInt 0])
            , powerValueProperty symbol
            , kNode "pin"
                [ kString "1"
                , kUuid (pageObjectUuid uuidSeed page 9 powerIndex)
                ]
            , kNode "instances"
                [ kNode "project"
                    [ kString ""
                    , kNode "path"
                        [ kString "/"
                        , kNode "reference" [kString reference]
                        , kNode "unit" [kInt 1]
                        ]
                    ]
                ]
            ]
      in kNode "symbol" fields

    powerValueProperty symbol =
      let name = powerNetName symbol
          x = powerHotX symbol
          y = powerHotY symbol
          hidden = powerStyle symbol == PowerGround
            || powerValueOffset symbol == Nothing
          -- Visible power labels are rendered text, so they must carry the same
          -- size/face as component fields; kProperty would emit a bare 1.27 with
          -- no (face ...), which KiCad renders in Newstroke instead of Arial.
          property
            | hidden = kHiddenProperty
            | otherwise = \n v a ->
                kStyledProperty n v a fieldSize fieldFace fieldBold fieldItalic
          atExpr = case powerValueCenter (useKicadFonts cfg)
                          fieldSize fieldFace fieldBold fieldItalic symbol of
            Just (mmX, mmY) -> kAt
              [ kDouble mmX
              , kDouble mmY
              , kInt (powerValueAngle symbol)
              ]
            Nothing -> kAt [kCoord x, kCoord y, kInt 0]
      in property "Value" name atExpr

    emitPageGraphic graphicIndex graphic =
      case graphic of
        PageRectangle style x1 y1 x2 y2 ->
          kNode "rectangle"
            [ kNode "start" [kCoord x1, kCoord y1]
            , kNode "end" [kCoord x2, kCoord y2]
            , pageGraphicStroke style
            , pageGraphicFill style
            , kUuid (pageObjectUuid uuidSeed page 11 graphicIndex)
            ]
        PageLine style x1 y1 x2 y2 ->
          pagePolyline graphicIndex style [(x1, y1), (x2, y2)] False
        PageEllipse style x1 y1 x2 y2 ->
          let cx = (fromIntegral x1 + fromIntegral x2) / 2 * unitToMm
              cy = (fromIntegral y1 + fromIntegral y2) / 2 * unitToMm
              rx = abs (fromIntegral (x2 - x1)) / 2 * unitToMm
              ry = abs (fromIntegral (y2 - y1)) / 2 * unitToMm
          in if abs (rx - ry) < 0.01
               then kNode "circle"
                 [ kNode "center" [kDouble cx, kDouble cy]
                 , kNode "radius" [kDouble rx]
                 , pageGraphicStroke style
                 , pageGraphicFill style
                 , kUuid (pageObjectUuid uuidSeed page 11 graphicIndex)
                 ]
               else pagePolylineMm graphicIndex style
                 (ellipsePoints cx cy rx ry 32) True
        PagePolygon style points ->
          pagePolyline graphicIndex style points True

    pagePolyline graphicIndex style points closeShape =
      pagePolylineMm graphicIndex style
        [ (fromIntegral x * unitToMm, fromIntegral y * unitToMm)
        | (x, y) <- points
        ]
        closeShape

    pagePolylineMm graphicIndex style points closeShape =
      let finalPoints = closePoints closeShape points
      in kNode "polyline"
          [ kNode "pts" [kXy x y | (x, y) <- finalPoints]
          , pageGraphicStroke style
          , pageGraphicFill style
          , kUuid (pageObjectUuid uuidSeed page 11 graphicIndex)
          ]

    closePoints shouldClose points = case points of
      [] -> []
      firstPoint : _
        | shouldClose && last points /= firstPoint -> points ++ [firstPoint]
        | otherwise -> points

    pageGraphicStroke style =
      let color = if graphicFillType style == "color"
            then Rgba 0 0 0 1
            else graphicColor style
      in kColoredStroke (graphicWidth style) (graphicStrokeType style) color

    pageGraphicFill style =
      let fillType = graphicFillType style
          color = if fillType `elem` ["color", "hatch"]
            then Just (graphicColor style)
            else Nothing
      in kPageFill fillType color

    emitPageText textIndex pageText =
      [ emitTextLine textIndex lineIndex lineText pageText style size rotation x y
      | (lineIndex, lineText) <- zip [(1 :: Int)..] textLines
      , let (x, y) = pageTextLinePosition pageText size rotation
              (lineIndex - 1) (length textLines)
      ]
      where
        style = textStyleForId textStyles (pageTextStyleId pageText)
        rotation = normalizedTextRotation (maybe 0 textStyleEscapement style)
        textLines = nonEmptyTextLines (pageTextValue pageText)
        size = pageTextSize (useKicadFonts cfg) pageText style textLines rotation

    emitTextLine textIndex lineIndex lineText pageText style size rotation x y =
      let face = if useKicadFonts cfg then "" else maybe "" textStyleFace style
          bold = maybe False ((== 700) . textStyleWeight) style
          italic = maybe False textStyleItalic style
      in kNode "text"
          [ kString lineText
          , kNo "exclude_from_sim"
          , kAt [kDouble x, kDouble y, kInt rotation]
          , kStyledTextEffects size face bold italic
              (Just (pageTextColor pageText))
              ["left", "bottom"]
          , kUuid (pageObjectUuid uuidSeed page 10 (textIndex * 1000 + lineIndex))
          ]

generateRootSch :: BS.ByteString -> String -> [Page] -> String
generateRootSch uuidSeed project pages =
  renderKicad $
    kNode "kicad_sch" $
      [ kNode "version" [kInt 20260306]
      , kNode "generator" [kString "dsn2kicad"]
      , kNode "generator_version" [kString "0.1"]
      , kUuid (stableObjectUuid uuidSeed 0 1)
      , kNode "paper" [kString "A3"]
      , kNode "title_block" [kNode "title" [kString (project ++ " (DSN import)")]]
      , kNode "lib_symbols" []
      ]
      ++ map emitSheet (zip [(1 :: Int)..] pages)
      ++ [ kNode "sheet_instances"
             [ kNode "path" [kString "/", kNode "page" [kString "1"]]
             ]
         , kNo "embedded_fonts"
         ]
  where
    -- The index sheet is A3 (420 x 297 mm).  Columns are filled top to bottom;
    -- growing the column height before adding columns keeps wide designs on the
    -- sheet instead of running off the right edge.  At most 6 columns fit
    -- (15 + 5 * 68 + 60 = 415) and at most 15 rows (25 + 14 * 17 + 12 = 275),
    -- and the four-row default is preserved for the designs that already fit.
    maxSheetColumns, maxSheetRows :: Int
    maxSheetColumns = 6
    maxSheetRows = 15
    rowsPerColumn =
      max 4 $ min maxSheetRows $
        (length pages + maxSheetColumns - 1) `div` maxSheetColumns

    emitSheet (idx, page) =
      let row = (idx - 1) `mod` rowsPerColumn
          col = (idx - 1) `div` rowsPerColumn
          x = 15 + col * 68
          y = 25 + row * 17
      in kNode "sheet"
           [ kAt [kInt x, kInt y]
           , kNode "size" [kRawNum "60", kRawNum "12"]
           , kNo "exclude_from_sim"
           , kYes "in_bom"
           , kYes "on_board"
           , kNo "dnp"
           , kYes "fields_autoplaced"
           , kStroke "0.1524" "solid"
           , kNode "fill" [kNode "color" [kInt 0, kInt 0, kInt 0, kInt 0]]
           , kUuid (stableObjectUuid uuidSeed 4 idx)
           , kProperty
               "Sheetname"
               (pageTitle page)
               (kAt [kInt x, kDouble (fromIntegral y - 0.7), kInt 0])
           , kProperty
               "Sheetfile"
               (pageOutputName page)
               (kAt [kInt x, kDouble (fromIntegral y + 12.7), kInt 0])
           ]

generateSymbolLibrary
  :: RenderConfig -> Map.Map String CacheSymbol -> MultiUnitRegistry -> [Page] -> String
generateSymbolLibrary cfg cacheSymbols multiUnits pages =
  renderKicad $
    kNode "kicad_symbol_lib" $
      [ kNode "version" [kInt 20251024]
      , kNode "generator" [kString "dsn2kicad"]
      , kNode "generator_version" [kString "0.1"]
      ]
      ++ emitSymbolDefinitions cfg cacheSymbols multiUnits
           [comp | page <- pages, comp <- pageComponents page]
           [symbol | page <- pages, symbol <- pagePowerSymbols page]

-- Symbol definitions for a set of placed components and power symbols: one
-- definition per referenced component cell, then one per power glyph.  A page's
-- embedded `lib_symbols` cache and the project-wide .kicad_sym are the same
-- list; they differ only in whether the scope is one page or all of them.
emitSymbolDefinitions
  :: RenderConfig
  -> Map.Map String CacheSymbol
  -> MultiUnitRegistry
  -> [Component]
  -> [PowerSymbol]
  -> [KExpr]
emitSymbolDefinitions cfg cacheSymbols multiUnits components powerSymbols =
  map emitUsedSymbol usedCells ++ map emitPowerDefinition powerDefinitions
  where
    usedCells = Map.elems $ Map.fromListWith (\_ earlier -> earlier)
      [ (componentLibName cfg multiUnits (compCell comp), compCell comp)
      | comp <- components
      ]

    emitUsedSymbol cellName
      | useKicadRc cfg && cellName `elem` ["R", "C"] =
          libStandardDeviceSymbol cellName
      | otherwise =
          let (libName, _) = componentUnitInfo multiUnits cellName
          in case Map.lookup libName (multiUnitGroups multiUnits) of
               Just units -> libMultiUnitSymbol libName units cacheSymbols
               Nothing -> libSymbol
                 (libName, Map.findWithDefault emptyCacheSymbol libName cacheSymbols)

    powerDefinitions = Map.toAscList $ Map.fromListWith preferPowerStyle
      [ (powerLibName cfg symbol, powerStyle symbol)
      | symbol <- powerSymbols
      , not (null (powerNetName symbol))
      ]

    preferPowerStyle PowerGround _ = PowerGround
    preferPowerStyle _ PowerGround = PowerGround
    preferPowerStyle new _ = new

    emitPowerDefinition (name, style)
      | useKicadPower cfg = libStandardPowerSymbol name
      | otherwise = libPowerSymbol name style

libPowerSymbol :: String -> PowerStyle -> KExpr
libPowerSymbol name style =
  kNode "symbol" $
    [ kString ("power:" ++ name)
    , kNode "power" []
    , kNode "pin_numbers" [kAtom "hide"]
    , kNode "pin_names" [kNode "offset" [kInt 0], kAtom "hide"]
    , kNo "exclude_from_sim"
    , kYes "in_bom"
    , kYes "on_board"
    , kHiddenProperty "Reference" "#PWR"
        (kAt [kInt 0, kDouble referenceY, kInt 0])
    , kProperty "Value" name
        (kAt [kInt 0, kDouble valueY, kInt 0])
    , kNode "symbol" (kString (name ++ "_0_1") : glyph)
    , kNode "symbol"
        [ kString (name ++ "_1_1")
        , kNode "pin"
            [ kAtom "power_in"
            , kAtom "line"
            , kAt [kInt 0, kInt 0, kInt pinAngle]
            , kNode "length" [kInt 0]
            , kNode "name" [kString name, kTextEffects]
            , kNode "number" [kString "1", kTextEffects]
            ]
        ]
    ]
  where
    referenceY = if style == PowerGround then -6.35 else -2.54
    valueY = case style of
      PowerGround -> -3.81
      PowerCircle -> 3.175
      PowerRail -> 2.286
    pinAngle = if style == PowerGround then 270 else 90
    glyph = case style of
      PowerGround ->
        [ kPolylineShape "0" "none"
            [ (0, 0), (0, -1.27), (1.27, -1.27)
            , (0, -2.54), (-1.27, -1.27), (0, -1.27)
            ]
        ]
      PowerRail ->
        [ kPolylineShape "0" "none" [(0, 0), (0, 1.27)]
        , kPolylineShape "0" "none" [(-1.27, 1.27), (1.27, 1.27)]
        ]
      PowerCircle ->
        [ kPolylineShape "0" "none" [(0, 0), (0, 1.27)]
        , kCircleShape 0 1.905 0.635
        ]

powerLibName :: RenderConfig -> PowerSymbol -> String
powerLibName cfg symbol
  | not (useKicadPower cfg) = powerNetName symbol
  | otherwise =
      Map.findWithDefault fallbackName
        (map toUpper (powerNetName symbol)) standardPowerNameMap
  where
    fallbackName = if powerStyle symbol == PowerGround then "GND" else "VCC"

standardPowerNameMap :: Map.Map String String
standardPowerNameMap = Map.fromList
  [ (map toUpper name, name)
  | name <-
      [ "+10V", "+12C", "+12L", "+12LF", "+12P", "+12V", "+12VA", "+15V"
      , "+1V0", "+1V1", "+1V2", "+1V35", "+1V5", "+1V8", "+24V", "+28V"
      , "+2V5", "+2V8", "+3.3V", "+3.3VA", "+3.3VADC", "+3.3VDAC"
      , "+3.3VP", "+36V", "+3V0", "+3V3", "+3V8", "+48V", "+4V", "+5C"
      , "+5F", "+5P", "+5V", "+5VA", "+5VD", "+5VL", "+5VP", "+6V"
      , "+7.5V", "+8V", "+9V", "+9VA", "+BATT", "+VDC", "+VSW"
      , "-10V", "-12V", "-12VA", "-15V", "-24V", "-2V5", "-36V", "-3V3"
      , "-48V", "-5V", "-5VA", "-6V", "-8V", "-9V", "-9VA", "-BATT"
      , "-VDC", "-VSW", "AC", "Earth", "Earth_Clean", "Earth_Protective"
      , "GND", "GND1", "GND2", "GND3", "GNDA", "GNDD", "GNDPWR", "GNDREF"
      , "GNDS", "HT", "LINE", "NEUT", "PRI_HI", "PRI_LO", "PRI_MID"
      , "PWR_FLAG", "VAA", "VAC", "VBUS", "VCC", "VCCQ", "VCOM", "VD"
      , "VDC", "VDD", "VDDA", "VDDF", "VEE", "VMEM", "VPP", "VS", "VSS"
      , "VSSA", "Vdrive"
      ]
  ]

libStandardPowerSymbol :: String -> KExpr
libStandardPowerSymbol name =
  kNode "symbol" $
    [ kString ("power:" ++ name)
    , kNode "power" [kAtom "global"]
    , kNode "pin_numbers" [kAtom "hide"]
    , kNode "pin_names" [kNode "offset" [kInt 0], kAtom "hide"]
    , kNo "exclude_from_sim"
    , kYes "in_bom"
    , kYes "on_board"
    , kHiddenProperty "Reference" "#PWR"
        (kAt [kInt 0, kDouble referenceY, kInt 0])
    , kProperty "Value" name (kAt [kInt 0, kDouble valueY, kInt 0])
    , kNode "symbol" (kString (name ++ "_0_1") : glyph)
    , kNode "symbol"
        [ kString (name ++ "_1_1")
        , standardPin "power_in" pinAngle 0 "" "1"
        ]
    ]
  where
    upper = map toUpper name
    groundGlyph = "GND" `isPrefixOf` upper || "EARTH" `isPrefixOf` upper
    negativeGlyph = negativeName || upper `elem` ["VEE", "VSS", "VSSA"]
    negativeName = case name of
      '-' : _ -> True
      _ -> False
    referenceY
      | groundGlyph = -6.35
      | negativeGlyph = 3.81
      | otherwise = -3.81
    valueY
      | groundGlyph = -3.81
      | negativeGlyph = -3.556
      | otherwise = 3.556
    pinAngle = if groundGlyph || negativeGlyph then 270 else 90
    glyph
      | groundGlyph =
          [ kPolylineShape "0" "none"
              [ (0, 0), (0, -1.27), (1.27, -1.27)
              , (0, -2.54), (-1.27, -1.27), (0, -1.27)
              ]
          ]
      | negativeGlyph =
          [ kPolylineShape "0" "none" [(-0.762, -1.27), (0, -2.54)]
          , kPolylineShape "0" "none" [(0, -2.54), (0.762, -1.27)]
          , kPolylineShape "0" "none" [(0, 0), (0, -2.54)]
          ]
      | otherwise =
          [ kPolylineShape "0" "none" [(-0.762, 1.27), (0, 2.54)]
          , kPolylineShape "0" "none" [(0, 2.54), (0.762, 1.27)]
          , kPolylineShape "0" "none" [(0, 0), (0, 2.54)]
          ]

libStandardDeviceSymbol :: String -> KExpr
libStandardDeviceSymbol name =
  kNode "symbol" $
    [ kString ("Device:" ++ name)
    , kNode "pin_numbers" [kAtom "hide"]
    , kNode "pin_names" [kNode "offset" [kRawNum "0.254"]]
    , kNo "exclude_from_sim"
    , kYes "in_bom"
    , kYes "on_board"
    , kProperty "Reference" name (kAt [kRawNum "0.635", kRawNum "2.54", kInt 0])
    , kProperty "Value" name (kAt [kRawNum "0.635", kRawNum "-2.54", kInt 0])
    , kNode "symbol" (kString (name ++ "_0_1") : body)
    , kNode "symbol"
        [ kString (name ++ "_1_1")
        , standardPin "passive" 270 pinLength "" "1"
        , standardPin "passive" 90 pinLength "" "2"
        ]
    ]
  where
    (body, pinLength) = case name of
      "C" ->
        ( [ kPolylineShape "0.508" "none" [(-2.032, 0.762), (2.032, 0.762)]
          , kPolylineShape "0.508" "none" [(-2.032, -0.762), (2.032, -0.762)]
          ]
        , 2.794
        )
      _ ->
        ( [ kNode "rectangle"
              [ kNode "start" [kRawNum "-1.016", kRawNum "-2.54"]
              , kNode "end" [kRawNum "1.016", kRawNum "2.54"]
              , kStroke "0.254" "default"
              , kFillType "none"
              ]
          ]
        , 1.27
        )

standardPin :: String -> Int -> Double -> String -> String -> KExpr
standardPin electricalType angle lengthMm name number =
  kNode "pin"
    [ kAtom electricalType
    , kAtom "line"
    , kAt [kInt 0, kDouble pinY, kInt angle]
    , kNode "length" [kDouble lengthMm]
    , kNode "name" [kString name, kTextEffects]
    , kNode "number" [kString number, kTextEffects]
    ]
  where
    pinY
      | lengthMm == 0 = 0
      | angle == 270 = 3.81
      | otherwise = -3.81

libSymbol :: (String, CacheSymbol) -> KExpr
libSymbol (name, symbol) =
  kNode "symbol" $
    [ kString name
    ]
    ++ symbolVisibilityNodes name symbol
    ++ libSymbolProperties name
    ++ symbolUnitNodes name 1 symbol

libMultiUnitSymbol
  :: String -> [(String, Int)] -> Map.Map String CacheSymbol -> KExpr
libMultiUnitSymbol baseName units cacheSymbols =
  kNode "symbol" $
    [ kString baseName
    , kNode "pin_names" [kNode "offset" [kRawNum "1.016"]]
    ]
    ++ libSymbolProperties baseName
    ++ concat
      [ symbolUnitNodes
          baseName
          unitNumber
          (Map.findWithDefault emptyCacheSymbol cellName cacheSymbols)
      | (cellName, unitNumber) <- sortOn snd units
      ]

libSymbolProperties :: String -> [KExpr]
libSymbolProperties name =
  [ kNo "exclude_from_sim"
    , kYes "in_bom"
    , kYes "on_board"
    , kProperty "Reference" "U" (kAt [kInt 0, kRawNum "2.54", kInt 0])
    , kProperty "Value" name (kAt [kInt 0, kRawNum "-2.54", kInt 0])
  ]

symbolVisibilityNodes :: String -> CacheSymbol -> [KExpr]
symbolVisibilityNodes name symbol =
  [ kNode "pin_numbers" [kAtom "hide"] | hidePinNumbers ]
  ++ [ kNode "pin_names"
         [ kNode "offset" [kRawNum "1.016"]
         , kAtom "hide"
         ]
     | hidePinNames
     ]
  where
    (hidePinNames, hidePinNumbers) = symbolPinVisibility name symbol

symbolUnitNodes :: String -> Int -> CacheSymbol -> [KExpr]
symbolUnitNodes name unitNumber symbol =
  [ kNode "symbol"
      (kString (name ++ "_" ++ show unitNumber ++ "_0") : bodyGraphics)
  , kNode "symbol"
      (kString (name ++ "_" ++ show unitNumber ++ "_1") : map emitPin pins)
  ]
  where
    pins = symbolPinsForOutput name symbol
    rects = cacheRects symbol
    segments = cacheLines symbol
    ellipses = cacheEllipses symbol
    arcs = cacheArcs symbol
    polygons = cachePolygons symbol
    polylines = cachePolylines symbol
    texts = cacheTexts symbol
    (originX, originY) = symbolOrigin symbol

    toSymX raw = (fromIntegral raw - originX) * unitToMm
    toSymY raw = negate ((fromIntegral raw - originY) * unitToMm)
    toSymPoint (x, y) = (toSymX x, toSymY y)

    bodyGraphics =
      map emitRect rects
      ++ map emitPolygon polygons
      ++ map emitOpenPolyline polylines
      ++ map emitSegment segments
      ++ map emitText texts
      ++ map emitEllipse ellipses
      ++ map emitArc arcs
      ++ fallbackBody

    fallbackBody
      | not hasExplicitBodyGraphics && not (null pins) =
          [ kRectangle (minX - pad) (minY - pad) (maxX + pad) (maxY + pad)
          ]
      | otherwise = []
      where
        bodyPoints = [(toSymX (pinBodyX pin), toSymY (pinBodyY pin)) | pin <- pins]
        xs = map fst bodyPoints
        ys = map snd bodyPoints
        minX = minimum xs
        maxX = maximum xs
        minY = minimum ys
        maxY = maximum ys
        pad = 1.27

    hasExplicitBodyGraphics =
      not (null rects)
      || not (null segments)
      || not (null ellipses)
      || not (null arcs)
      || not (null polygons)
      || not (null polylines)
      || not (null texts)

    emitRect (Rect x1 y1 x2 y2) =
      kRectangle (toSymX x1) (toSymY y1) (toSymX x2) (toSymY y2)

    kRectangle x1 y1 x2 y2 =
      kNode "rectangle"
        [ kNode "start" [kDouble x1, kDouble y1]
        , kNode "end" [kDouble x2, kDouble y2]
        , kStroke "0.1524" "default"
        , kFillType "none"
        ]

    emitSegment (Segment x1 y1 x2 y2) =
      kPolylineShape "0.1524" "none"
        [(toSymX x1, toSymY y1), (toSymX x2, toSymY y2)]

    emitPolygon (Polygon points) =
      kPolylineShape "0" "outline" (map toSymPoint points)

    emitOpenPolyline (Polyline points) =
      kPolylineShape "0.254" "none" (map toSymPoint points)

    emitText (TextAnnotation x1 y1 x2 y2 _ax _ay text) =
      let mx = (fromIntegral x1 + fromIntegral x2) / 2
          my = (fromIntegral y1 + fromIntegral y2) / 2
          angle = if abs (y2 - y1) > abs (x2 - x1) then 900 else 0
          tx = (mx - originX) * unitToMm
          ty = negate ((my - originY) * unitToMm)
      in kNode "text"
          [ kString text
          , kAt [kDouble tx, kDouble ty, kInt angle]
          , kTextEffects
          ]

    emitEllipse (Ellipse x1 y1 x2 y2) =
      let sx1 = toSymX x1
          sy1 = toSymY y1
          sx2 = toSymX x2
          sy2 = toSymY y2
          cx = (sx1 + sx2) / 2
          cy = (sy1 + sy2) / 2
          rx = abs (sx2 - sx1) / 2
          ry = abs (sy2 - sy1) / 2
      in if abs (rx - ry) < 0.01
           then kCircleShape cx cy rx
           else kPolylineShape "0.254" "none" (ellipsePoints cx cy rx ry 32)

    emitArc (ArcShape x1 y1 x2 y2 startX startY endX endY) =
      let sx1 = toSymX x1
          sy1 = toSymY y1
          sx2 = toSymX x2
          sy2 = toSymY y2
          cx = (sx1 + sx2) / 2
          cy = (sy1 + sy2) / 2
          rx = abs (sx2 - sx1) / 2
          ry = abs (sy2 - sy1) / 2
          sx = toSymX startX
          sy = toSymY startY
          ex = toSymX endX
          ey = toSymY endY
          (mx, my) = arcMidpoint cx cy rx ry sx sy ex ey
      in if abs (rx - ry) < 0.01
           then kArcShape sx sy mx my ex ey
           else kPolylineShape "0.254" "none" (arcPoints cx cy rx ry sx sy ex ey 32)

    emitPin pin =
      kNode "pin"
        [ kAtom (pinElectricalType pin)
        , kAtom "line"
        , kAt
            [ kDouble (toSymX (pinHotX pin))
            , kDouble (toSymY (pinHotY pin))
            , kInt (pinAngle pin)
            ]
        , kNode "length" [kDouble (pinLength pin)]
        , kNode "name" [kString (orcadOverlineToKicad (pinName pin)), kTextEffects]
        , kNode "number" [kString (orcadOverlineToKicad (pinNumber pin)), kTextEffects]
        ]

    pinLength pin =
      let dx = toSymX (pinBodyX pin) - toSymX (pinHotX pin)
          dy = toSymY (pinBodyY pin) - toSymY (pinHotY pin)
      in sqrt (dx * dx + dy * dy)

    pinAngle pin =
      let dx = toSymX (pinBodyX pin) - toSymX (pinHotX pin)
          dy = toSymY (pinBodyY pin) - toSymY (pinHotY pin)
      in directionFromVector dx dy

generateProject :: String -> Bool -> String
generateProject project emitWorksheet =
  unlines $
    [ "{"
    , "  \"meta\": {"
    , "    \"filename\": \"" ++ escJson project ++ ".kicad_pro\","
    , "    \"version\": 2"
    , "  },"
    , "  \"schematic\": {"
    , "    \"drawing\": {},"
    , "    \"meta\": {"
    , "      \"version\": 1"
    , "    }" ++ if emitWorksheet then "," else ""
    ]
    ++ [ "    \"page_layout_descr_file\": \"" ++ escJson project ++ ".kicad_wks\""
       | emitWorksheet
       ]
    ++
    [ "  }"
    , "}"
    ]

generateSymLibTable :: String -> String
generateSymLibTable project =
  unlines
    [ "(sym_lib_table"
    , "  (version 7)"
    , "  (lib (name \"" ++ esc project ++ "\")(type \"KiCad\")(uri \"${KIPRJMOD}/" ++ esc project ++ ".kicad_sym\")(options \"\")(descr \"\"))"
    , ")"
    ]

generateWorksheet :: String
generateWorksheet =
  unlines
    [ "(page_layout"
    , "  (setup (textsize 1.5 1.5) (linewidth 0.15) (textlinewidth 0.15)"
    , "    (left_margin 0) (right_margin 0) (top_margin 0) (bottom_margin 0))"
    , "  (rect (comment \"rect around the title block\") (linewidth 0.15) (start 110 34) (end 2 2))"
    , "  (rect (start 0 0 ltcorner) (end 0 0 rbcorner) (repeat 2) (incrx 2) (incry 2))"
    , "  (line (start 50 2 ltcorner) (end 50 0 ltcorner) (repeat 30) (incrx 50))"
    , "  (tbtext \"1\" (pos 25 1 ltcorner) (font (size 1.3 1.3)) (repeat 100) (incrx 50))"
    , "  (line (start 50 2 lbcorner) (end 50 0 lbcorner) (repeat 30) (incrx 50))"
    , "  (tbtext \"1\" (pos 25 1 lbcorner) (font (size 1.3 1.3)) (repeat 100) (incrx 50))"
    , "  (line (start 0 50 ltcorner) (end 2 50 ltcorner) (repeat 30) (incry 50))"
    , "  (tbtext \"A\" (pos 1 25 ltcorner) (font (size 1.3 1.3)) (justify center) (repeat 100) (incry 50))"
    , "  (line (start 0 50 rtcorner) (end 2 50 rtcorner) (repeat 30) (incry 50))"
    , "  (tbtext \"A\" (pos 1 25 rtcorner) (font (size 1.3 1.3)) (justify center) (repeat 100) (incry 50))"
    , "  (tbtext \"Date: %D\" (pos 87 6.9))"
    , "  (line (start 110 5.5) (end 2 5.5))"
    , "  (tbtext \"%K\" (pos 109 4.1) (comment \"KiCad version\"))"
    , "  (line (start 110 8.5) (end 2 8.5))"
    , "  (tbtext \"Rev: %R\" (pos 24 6.9) (font bold) (justify left))"
    , "  (tbtext \"Size: %Z\" (comment \"Paper format name\") (pos 109 6.9))"
    , "  (tbtext \"Id: %S/%N\" (comment \"Sheet id\") (pos 24 4.1))"
    , "  (line (start 110 12.5) (end 2 12.5))"
    , "  (tbtext \"Title: %T\" (pos 109 10.7) (font bold italic (size 2 2)))"
    , "  (tbtext \"File: %F\" (pos 109 14.3))"
    , "  (line (start 110 18.5) (end 2 18.5))"
    , "  (tbtext \"Sheet: %P\" (pos 109 17))"
    , "  (tbtext \"%Y\" (comment \"Company name\") (pos 109 20) (font bold))"
    , "  (tbtext \"%C0\" (comment \"Comment 0\") (pos 109 23))"
    , "  (tbtext \"%C1\" (comment \"Comment 1\") (pos 109 26))"
    , "  (tbtext \"%C2\" (comment \"Comment 2\") (pos 109 29))"
    , "  (tbtext \"%C3\" (comment \"Comment 3\") (pos 109 32))"
    , "  (line (start 90 8.5) (end 90 5.5))"
    , "  (line (start 26 8.5) (end 26 2))"
    , ")"
    ]

pageObjectUuid :: BS.ByteString -> Page -> Int -> Int -> String
pageObjectUuid seed page category objectIndex =
  deterministicUuid seed $
    pageStreamName page ++ ":" ++ show category ++ ":" ++ show objectIndex

pagePinUuid :: BS.ByteString -> Page -> Int -> Int -> String
pagePinUuid seed page componentIndex pinIndex =
  pageObjectUuid seed page 3 (componentIndex * 1000000 + pinIndex)
