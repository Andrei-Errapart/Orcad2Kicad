{-# LANGUAGE ScopedTypeVariables #-}

-- Copyright (C) 2026 Andrei Errapart
-- SPDX-License-Identifier: GPL-2.0-or-later

-- Entry point.  Not directly executable: with the converter split across
-- modules GHC needs -i, which a shebang cannot supply.  Use scripts/dsn2kicad.
module Main (main) where

import Binary
  ( byteAt, word16LE, word32LE, word64LE, int16LE, int32LE
  , sliceAt, words32LE, readI32Quad, readI32Oct
  , findSubFrom, findSubBefore, findAll, findAllFrom
  , asciiAt, asciiPrefixAt, isPrintableAscii, extractStrings
  , word64ToInt, word32ToInt, maybeWord32ToInt, showHex32
  , need, unlessEither, firstJust, lookupList, listAt, orElse
  , unique, splitSlash, stripStringPrefix, dedupeConsecutive
  , commonStringPrefix, trimTrailingUnderscores
  )
import Control.Monad (forM_, guard, unless)
import Data.Bits ((.&.))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Char (isAlpha, isAlphaNum, isDigit, isSpace, ord, toLower, toUpper)
import Data.List
  ( elemIndex
  , intercalate
  , isInfixOf
  , isPrefixOf
  , isSuffixOf
  , sortOn
  )
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, mapMaybe)
import qualified Data.Set as Set
import Data.Word (Word8, Word32)
import Dsn.Record
  ( recordMarker, netTableAnchor, textRecordType
  , pageRectTag, pageLineTag, pageEllipseTag, pagePolygonTag
  , findCellMatches
  )
import Encoding
  ( SourceEncoding, sourceEncodingByName, sourceEncodingNames
  , encodingFlagPrefix, decodeLibraryString, detectSourceEncoding
  , decodeUtf16LeName
  )
import Numeric (showFFloat)
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
import Text.MetricsTables (FaceMetrics(..), fontMetrics)
import Utf8 (utf8Encode)
import Uuid (deterministicUuid, stableObjectUuid)

unitToMm :: Double
unitToMm = 0.254

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

-- | The rendering flags, separated from the CLI record so that geometry and
-- text layout do not depend on how the program was invoked.
data RenderConfig = RenderConfig
  { useKicadPower :: Bool
  , useKicadRc :: Bool
  , useKicadFonts :: Bool
  }

renderConfigOf :: Options -> RenderConfig
renderConfigOf opts = RenderConfig
  { useKicadPower = optKicadPower opts
  , useKicadRc = optKicadRc opts
  , useKicadFonts = optKicadFonts opts
  }

data ZipMember = ZipMember FilePath BS.ByteString
  deriving Show

data DirEntry = DirEntry
  { dirName :: String
  , dirType :: Word8
  , dirLeft :: Maybe Int
  , dirRight :: Maybe Int
  , dirChild :: Maybe Int
  , dirStartSector :: Word32
  , dirStreamSize :: Int
  }
  deriving Show

data OleFile = OleFile
  { oleBytes :: BS.ByteString
  , oleSectorSize :: Int
  , oleMiniSectorSize :: Int
  , oleMiniCutoff :: Int
  , oleFat :: Map.Map Int Word32
  , oleMiniFat :: Map.Map Int Word32
  , oleMiniStream :: BS.ByteString
  , oleDirectory :: [DirEntry]
  }
  deriving Show

data Page = Page
  { pageStreamName :: FilePath
  , pageOutputName :: FilePath
  , pageTitle :: String
  , pageTitleBlock :: TitleBlock
  , pagePaper :: String
  , pageNets :: Map.Map Int String
  , pageWires :: [Wire]
  , pageNetAliases :: [NetLabel]
  , pageOffPageConnectors :: [OffPageConnector]
  , pageComponents :: [Component]
  , pagePowerSymbols :: [PowerSymbol]
  , pageTexts :: [PageText]
  , pageGraphics :: [PageGraphic]
  }
  deriving Show

data Wire = Wire
  { wireNetId :: Int
  , wireNetName :: String
  , wireX1 :: Int
  , wireY1 :: Int
  , wireX2 :: Int
  , wireY2 :: Int
  , wireIsBus :: Bool
  }
  deriving Show

data NetLabel = NetLabel
  { netLabelGlobal :: Bool
  , netLabelName :: String
  , netLabelX :: Int
  , netLabelY :: Int
  , netLabelAngle :: Int
  }
  deriving (Eq, Ord, Show)

data OffPageConnector = OffPageConnector
  { offPageNetName :: String
  , offPageX :: Int
  , offPageY :: Int
  , offPageAngle :: Int
  , offPageMatched :: Bool
  }
  deriving Show

data Component = Component
  { compCell :: String
  , compRef :: String
  , compValue :: String
  , compX :: Int
  , compY :: Int
  , compOrient :: Int
  , compPagePins :: [PagePin]
  , compLocX :: Int
  , compLocY :: Int
  , compRefField :: Maybe DisplayField
  , compValueField :: Maybe DisplayField
  , compOriginX :: Maybe Double
  , compOriginY :: Maybe Double
  }
  deriving Show

data DisplayField = DisplayField
  { displayPropertyIndex :: Int
  , displayOffsetX :: Int
  , displayOffsetY :: Int
  , displayTextAngle :: Int
  }
  deriving Show

data PagePin = PagePin
  { pagePinNumber :: Int
  , pagePinX :: Int
  , pagePinY :: Int
  , pagePinNetId :: Int
  , pagePinNetName :: String
  }
  deriving Show

data PowerStyle = PowerGround | PowerRail | PowerCircle
  deriving (Eq, Ord, Show)

data PowerSymbol = PowerSymbol
  { powerNetName :: String
  , powerStyle :: PowerStyle
  , powerCoords :: (Int, Int, Int, Int, Int, Int)
  , powerOrient :: Int
  , powerHotX :: Int
  , powerHotY :: Int
  , powerMatched :: Bool
  , powerValueOffset :: Maybe (Int, Int)
  , powerValueRotation :: Maybe Int
  }
  deriving Show

data Rgba = Rgba Int Int Int Int
  deriving (Eq, Show)

data PageText = PageText
  { pageTextValue :: String
  , pageTextX1 :: Int
  , pageTextY1 :: Int
  , pageTextX2 :: Int
  , pageTextY2 :: Int
  , pageTextStyleId :: Int
  , pageTextColor :: Rgba
  }
  deriving Show

data GraphicStyle = GraphicStyle
  { graphicColor :: Rgba
  , graphicWidth :: Double
  , graphicStrokeType :: String
  , graphicFillType :: String
  }
  deriving Show

data PageGraphic
  = PageRectangle GraphicStyle Int Int Int Int
  | PageLine GraphicStyle Int Int Int Int
  | PageEllipse GraphicStyle Int Int Int Int
  | PagePolygon GraphicStyle [(Int, Int)]
  deriving Show

data TextStyle = TextStyle
  { textStyleTag :: Int
  , textStyleWeight :: Int
  , textStyleItalic :: Bool
  , textStyleEscapement :: Int
  , textStyleFace :: String
  }
  deriving Show

data TitleBlock = TitleBlock
  { titleBlockTitle :: String
  , titleBlockDocumentNumber :: String
  , titleBlockRevision :: String
  , titleBlockCompany :: String
  , titleBlockDate :: String
  }
  deriving Show

-- | Header of a page stream: the name and paper size, the page's
-- modification time, and the property table that carries the
-- title-block field values.  See `parsePageHeader`.
data PageHeader = PageHeader
  { pageHeaderName :: String
  , pageHeaderPaper :: String
  , pageHeaderModified :: Maybe Int
  , pageHeaderProperties :: [(Int, Int)]
  }
  deriving Show

data Pin = Pin
  { pinName :: String
  , pinNumber :: String
  , pinHotX :: Int
  , pinHotY :: Int
  , pinBodyX :: Int
  , pinBodyY :: Int
  , pinFlags :: Int
  }
  deriving Show

data Rect = Rect Int Int Int Int
  deriving Show

data Segment = Segment Int Int Int Int
  deriving Show

data Ellipse = Ellipse Int Int Int Int
  deriving Show

data ArcShape = ArcShape Int Int Int Int Int Int Int Int
  deriving Show

data Polygon = Polygon [(Int, Int)]
  deriving Show

data Polyline = Polyline [(Int, Int)]
  deriving Show

data TextAnnotation = TextAnnotation Int Int Int Int Int Int String
  deriving Show

data CacheSymbol = CacheSymbol
  { cachePins :: [Pin]
  , cachePinNamesVisible :: Maybe Bool
  , cachePinNumbersVisible :: Maybe Bool
  , cacheRects :: [Rect]
  , cacheLines :: [Segment]
  , cacheEllipses :: [Ellipse]
  , cacheArcs :: [ArcShape]
  , cachePolygons :: [Polygon]
  , cachePolylines :: [Polyline]
  , cacheTexts :: [TextAnnotation]
  }
  deriving Show

emptyCacheSymbol :: CacheSymbol
emptyCacheSymbol = CacheSymbol [] Nothing Nothing [] [] [] [] [] [] []

data MultiUnitRegistry = MultiUnitRegistry
  { multiUnitGroups :: Map.Map String [(String, Int)]
  , multiUnitCells :: Map.Map String (String, Int)
  }
  deriving Show

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

isZipArchive :: BS.ByteString -> Bool
isZipArchive = BS.isPrefixOf (BS.pack [0x50, 0x4b, 0x03, 0x04])

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

pageStreamPath :: FilePath -> Maybe (String, String)
pageStreamPath path =
  case splitSlash path of
    ["Views", viewName, "Pages", pageName]
      | not (null viewName) && not (null pageName) -> Just (viewName, pageName)
    _ -> Nothing

disambiguatePageOutputName :: String -> Page -> Page
disambiguatePageOutputName project page
  | pageOutputName page == project ++ ".kicad_sch" =
      page { pageOutputName = project ++ "_sheet.kicad_sch" }
  | otherwise = page

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

parseStoredZip :: BS.ByteString -> Either String [ZipMember]
parseStoredZip bytes = go 0 []
  where
    go off acc
      | off + 4 > BS.length bytes = Right (reverse acc)
      | u32 off == Just 0x04034b50 = do
          flags <- need "ZIP flags" (u16 (off + 6))
          compression <- need "ZIP compression method" (u16 (off + 8))
          compressedSize <- need "ZIP compressed size" (u32 (off + 18))
          nameLen <- need "ZIP filename length" (u16 (off + 26))
          extraLen <- need "ZIP extra length" (u16 (off + 28))
          let dataStart =
                off + 30 + fromIntegral nameLen + fromIntegral extraLen
              dataEnd = dataStart + fromIntegral compressedSize
              nameStart = off + 30
              nameEnd = nameStart + fromIntegral nameLen
          unlessEither (flags .&. 0x0008 == 0) $
            "ZIP data descriptors are not supported by the native Haskell reader"
          unlessEither (compression == 0) $
            "only stored ZIP members are supported by the native Haskell reader"
          unlessEither (dataEnd <= BS.length bytes && nameEnd <= BS.length bytes) $
            "truncated ZIP member"
          let name = BSC.unpack (BS.take (fromIntegral nameLen) (BS.drop nameStart bytes))
              body = BS.take (fromIntegral compressedSize) (BS.drop dataStart bytes)
          go dataEnd (ZipMember name body : acc)
      | otherwise = Right (reverse acc)

    u16 = word16LE bytes
    u32 = word32LE bytes

oleMagic :: BS.ByteString
oleMagic = BS.pack [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]

maxRegularSector, endOfChain, noStream :: Word32
maxRegularSector = 0xfffffffa
endOfChain = 0xfffffffe
noStream = 0xffffffff

parseOleStreams :: BS.ByteString -> Either String [(FilePath, BS.ByteString)]
parseOleStreams bytes = do
  ole <- parseOleFile bytes
  collectOleStreams ole

parseOleFile :: BS.ByteString -> Either String OleFile
parseOleFile bytes = do
  unlessEither (BS.isPrefixOf oleMagic bytes) "not an OLE compound document"
  sectorShift <- need "OLE sector shift" (word16LE bytes 0x1e)
  miniSectorShift <- need "OLE mini sector shift" (word16LE bytes 0x20)
  numFatSectors <- need "OLE FAT sector count" (word32LE bytes 0x2c)
  firstDirSector <- need "OLE first directory sector" (word32LE bytes 0x30)
  miniCutoff <- need "OLE mini stream cutoff" (word32LE bytes 0x38)
  firstMiniFatSector <- need "OLE first mini FAT sector" (word32LE bytes 0x3c)
  numMiniFatSectors <- need "OLE mini FAT sector count" (word32LE bytes 0x40)
  firstDifatSector <- need "OLE first DIFAT sector" (word32LE bytes 0x44)
  numDifatSectors <- need "OLE DIFAT sector count" (word32LE bytes 0x48)

  unlessEither (sectorShift == 9 || sectorShift == 12) $
    "unsupported OLE sector size shift: " ++ show sectorShift
  unlessEither (miniSectorShift == 6) $
    "unsupported OLE mini sector size shift: " ++ show miniSectorShift

  let sectorSize = 2 ^ (fromIntegral sectorShift :: Int)
      miniSectorSize = 2 ^ (fromIntegral miniSectorShift :: Int)
      headerFatSectors =
        filter isRegularSector
          [ sid
          | i <- [0 .. 108]
          , Just sid <- [word32LE bytes (0x4c + i * 4)]
          ]
  difatSectors <- parseDifatSectors bytes sectorSize firstDifatSector numDifatSectors
  let fatSectorIds =
        take (fromIntegral numFatSectors) (headerFatSectors ++ difatSectors)
  unlessEither (length fatSectorIds == fromIntegral numFatSectors) $
    "truncated OLE FAT sector list"
  fatEntries <- concat <$> mapM (sectorWords bytes sectorSize) fatSectorIds
  let fat = Map.fromList (zip [0..] fatEntries)

  dirBytes <- readSectorChainBytes bytes sectorSize fat firstDirSector
  dirs <- parseDirectoryEntries dirBytes
  root <- directoryEntryAt dirs 0
  miniFatBytes <-
    if numMiniFatSectors == 0 || not (isRegularSector firstMiniFatSector)
      then Right BS.empty
      else readSectorChainBytesLimit
             bytes sectorSize fat firstMiniFatSector (fromIntegral numMiniFatSectors)
  let miniFat = Map.fromList (zip [0..] (words32LE miniFatBytes))
  miniStream <-
    if dirStreamSize root == 0 || not (isRegularSector (dirStartSector root))
      then Right BS.empty
      else readSectorChainBytesTake
             bytes sectorSize fat (dirStartSector root) (dirStreamSize root)

  Right OleFile
    { oleBytes = bytes
    , oleSectorSize = sectorSize
    , oleMiniSectorSize = miniSectorSize
    , oleMiniCutoff = fromIntegral miniCutoff
    , oleFat = fat
    , oleMiniFat = miniFat
    , oleMiniStream = miniStream
    , oleDirectory = dirs
    }

parseDifatSectors
  :: BS.ByteString -> Int -> Word32 -> Word32 -> Either String [Word32]
parseDifatSectors bytes sectorSize firstSector count = go firstSector count []
  where
    entriesPerSector = sectorSize `div` 4 - 1

    go _ 0 acc = Right (reverse acc)
    go sid remaining acc
      | not (isRegularSector sid) = Left "truncated OLE DIFAT chain"
      | otherwise = do
          sector <- need "OLE DIFAT sector" (readSector bytes sectorSize sid)
          let wordsInSector = words32LE sector
              entries = take entriesPerSector wordsInSector
              nextSid =
                fromMaybe endOfChain $
                  word32LE sector (sectorSize - 4)
          go nextSid (remaining - 1) (reverse (filter isRegularSector entries) ++ acc)

sectorWords :: BS.ByteString -> Int -> Word32 -> Either String [Word32]
sectorWords bytes sectorSize sid = do
  sector <- need ("OLE sector " ++ show sid) (readSector bytes sectorSize sid)
  Right (words32LE sector)

parseDirectoryEntries :: BS.ByteString -> Either String [DirEntry]
parseDirectoryEntries bytes =
  mapM parseEntry [0, 128 .. BS.length bytes - 128]
  where
    parseEntry off = do
      entry <- need "OLE directory entry" (sliceAt bytes off 128)
      nameLen <- need "OLE directory name length" (word16LE entry 64)
      objectType <- need "OLE directory object type" (byteAt entry 66)
      leftSid <- need "OLE left sibling id" (word32LE entry 68)
      rightSid <- need "OLE right sibling id" (word32LE entry 72)
      childSid <- need "OLE child id" (word32LE entry 76)
      startSector <- need "OLE stream start sector" (word32LE entry 116)
      size64 <- need "OLE stream size" (word64LE entry 120)
      size <- word64ToInt "OLE stream size" size64
      let usableNameBytes
            | nameLen >= 2 && nameLen <= 64 = fromIntegral nameLen - 2
            | otherwise = 0
          name = decodeUtf16LeName (BS.take usableNameBytes entry)
      Right DirEntry
        { dirName = name
        , dirType = objectType
        , dirLeft = sidToMaybe leftSid
        , dirRight = sidToMaybe rightSid
        , dirChild = sidToMaybe childSid
        , dirStartSector = startSector
        , dirStreamSize = size
        }

collectOleStreams :: OleFile -> Either String [(FilePath, BS.ByteString)]
collectOleStreams ole = do
  root <- directoryEntryAt (oleDirectory ole) 0
  (_, streams) <- collectChildren (Set.singleton 0) [] (dirChild root)
  Right streams
  where
    collectChildren seen _ Nothing = Right (seen, [])
    collectChildren seen prefix (Just sid)
      | Set.member sid seen =
          Left ("OLE directory entry cycle at SID " ++ show sid)
      | otherwise = do
          entry <- directoryEntryAt (oleDirectory ole) sid
          let seen' = Set.insert sid seen
          (afterLeft, left) <- collectChildren seen' prefix (dirLeft entry)
          (afterCurrent, current) <- collectEntry afterLeft prefix entry
          (afterRight, right) <-
            collectChildren afterCurrent prefix (dirRight entry)
          Right (afterRight, left ++ current ++ right)

    collectEntry seen prefix entry
      | dirType entry == 1 =
          collectChildren seen (prefix ++ [dirName entry]) (dirChild entry)
      | dirType entry == 5 = collectChildren seen prefix (dirChild entry)
      | dirType entry == 2 = do
          body <- readOleStream ole entry
          Right (seen, [(intercalate "/" (prefix ++ [dirName entry]), body)])
      | otherwise = Right (seen, [])

readOleStream :: OleFile -> DirEntry -> Either String BS.ByteString
readOleStream ole entry
  | dirStreamSize entry == 0 = Right BS.empty
  | dirStreamSize entry < oleMiniCutoff ole =
      readMiniSectorChainBytesTake
        (oleMiniStream ole)
        (oleMiniSectorSize ole)
        (oleMiniFat ole)
        (dirStartSector entry)
        (dirStreamSize entry)
  | otherwise =
      readSectorChainBytesTake
        (oleBytes ole)
        (oleSectorSize ole)
        (oleFat ole)
        (dirStartSector entry)
        (dirStreamSize entry)

directoryEntryAt :: [DirEntry] -> Int -> Either String DirEntry
directoryEntryAt entries sid
  | sid >= 0 && sid < length entries = Right (entries !! sid)
  | otherwise = Left ("OLE directory SID out of range: " ++ show sid)

readSectorChainBytes
  :: BS.ByteString -> Int -> Map.Map Int Word32 -> Word32 -> Either String BS.ByteString
readSectorChainBytes bytes sectorSize fat startSid = do
  chain <- sectorChain fat startSid
  sectors <- mapM (need "OLE chained sector" . readSector bytes sectorSize) chain
  Right (BS.concat sectors)

readSectorChainBytesLimit
  :: BS.ByteString
  -> Int
  -> Map.Map Int Word32
  -> Word32
  -> Int
  -> Either String BS.ByteString
readSectorChainBytesLimit bytes sectorSize fat startSid limit = do
  chain <- take limit <$> sectorChain fat startSid
  sectors <- mapM (need "OLE chained sector" . readSector bytes sectorSize) chain
  Right (BS.concat sectors)

readSectorChainBytesTake
  :: BS.ByteString -> Int -> Map.Map Int Word32 -> Word32 -> Int -> Either String BS.ByteString
readSectorChainBytesTake bytes sectorSize fat startSid size = do
  body <- readSectorChainBytes bytes sectorSize fat startSid
  unlessEither (BS.length body >= size) "truncated OLE stream chain"
  Right (BS.take size body)

readMiniSectorChainBytesTake
  :: BS.ByteString -> Int -> Map.Map Int Word32 -> Word32 -> Int -> Either String BS.ByteString
readMiniSectorChainBytesTake miniStream miniSectorSize miniFat startSid size = do
  chain <- sectorChain miniFat startSid
  sectors <- mapM readMiniSector chain
  let body = BS.concat sectors
  unlessEither (BS.length body >= size) "truncated OLE mini stream chain"
  Right (BS.take size body)
  where
    readMiniSector sid = do
      sidInt <- word32ToInt "OLE mini sector id" sid
      let start = sidInt * miniSectorSize
      need "OLE mini sector" (sliceAt miniStream start miniSectorSize)

sectorChain :: Map.Map Int Word32 -> Word32 -> Either String [Word32]
sectorChain table startSid = go Map.empty [] startSid
  where
    -- Termination rests on `seen`: every visited sector is recorded, and a
    -- sector missing from the FAT ends the walk, so the chain cannot outrun the
    -- table.  An additional length check would be redundant and, because it
    -- measured the accumulator, quadratic in the chain length.
    go seen acc sid
      | sid == endOfChain = Right (reverse acc)
      | not (isRegularSector sid) =
          Left ("unexpected OLE sector marker in chain: " ++ showHex32 sid)
      | Map.member (fromIntegral sid :: Int) seen = Left "OLE sector chain cycle"
      | otherwise = do
          sidInt <- word32ToInt "OLE sector id" sid
          next <- need ("OLE FAT entry for sector " ++ show sidInt) (Map.lookup sidInt table)
          go (Map.insert sidInt () seen) (sid : acc) next

readSector :: BS.ByteString -> Int -> Word32 -> Maybe BS.ByteString
readSector bytes sectorSize sid = do
  sidInt <- maybeWord32ToInt sid
  let start = (sidInt + 1) * sectorSize
  sliceAt bytes start sectorSize

sidToMaybe :: Word32 -> Maybe Int
sidToMaybe sid
  | sid == noStream = Nothing
  | otherwise = maybeWord32ToInt sid

isRegularSector :: Word32 -> Bool
isRegularSector sid = sid <= maxRegularSector

parsePage :: [String] -> FilePath -> BS.ByteString -> Page
parsePage libraryValues streamName body =
  let header = parsePageHeader libraryValues body
      title = pageHeaderName header
      paper = pageHeaderPaper header
      nets = parseNetTable body
      wires = parseWires nets body
      aliases = parseNetAliases nets body
      comps = parseComponents libraryValues nets body
      offPageConnectors = resolveOffPageConnectors wires comps aliases
        (parseOffPageConnectors body)
      powerSymbols = resolvePowerSymbols wires comps (parsePowerSymbols body)
      texts = parsePageTexts paper body
      graphics = parsePageGraphics paper body
  in Page
    { pageStreamName = streamName
    , pageOutputName = sanitizePageName (takeFileName streamName) ++ ".kicad_sch"
    , pageTitle = sanitizePageName (if null title then takeFileName streamName else title)
    , pageTitleBlock = resolveTitleBlock libraryValues header
    , pagePaper = paper
    , pageNets = nets
    , pageWires = wires
    , pageNetAliases = aliases
    , pageOffPageConnectors = offPageConnectors
    , pageComponents = comps
    , pagePowerSymbols = powerSymbols
    , pageTexts = texts
    , pageGraphics = graphics
    }

paperSizes :: [String]
paperSizes = ["A0", "A1", "A2", "A3", "A4", "A", "B", "C", "D", "E"]

-- | The page header stores the page name and paper size inline, then the
-- creation and modification times as Unix `time_t`, and ends with the
-- property table decoded by `parsePagePropertyTable`.
--
-- Streams written before OrCAD 16.x carry no record marker and no
-- property table; those keep the name/paper pair only.
parsePageHeader :: [String] -> BS.ByteString -> PageHeader
parsePageHeader values body =
  case findSubFrom recordMarker 0 body >>= parseAt of
    Just parsed -> parsed
    Nothing -> fromMaybe (PageHeader fallbackName "A3" Nothing []) parseLegacyHeader
  where
    parseAt idx = do
      nameLen <- word16LE body (idx + 8)
      guard (nameLen >= 1 && nameLen <= 50)
      name <- asciiAt body (idx + 10) (fromIntegral nameLen)
      let paperPos = idx + 10 + fromIntegral nameLen + 1
      paperLen <- word16LE body paperPos
      guard (paperLen >= 1 && paperLen <= 5)
      paper <- asciiAt body (paperPos + 2) (fromIntegral paperLen)
      guard (paper `elem` paperSizes)
      let afterPaper = paperPos + 2 + fromIntegral paperLen + 1
      pure PageHeader
        { pageHeaderName = name
        , pageHeaderPaper = paper
        , pageHeaderModified = plausibleTime (word32LE body (afterPaper + 4))
        , pageHeaderProperties =
            parsePagePropertyTable values body afterPaper tableEnd
        }
      where
        -- The property table runs up to the start of the next record.
        tableEnd = fromMaybe (BS.length body)
          (findSubFrom recordMarker (idx + 4) body)

    parseLegacyHeader = do
      nameLen <- word16LE body 3
      guard (nameLen >= 1 && nameLen <= 50)
      name <- asciiAt body 5 (fromIntegral nameLen)
      let nameEnd = 5 + fromIntegral nameLen
      guard (byteAt body nameEnd == Just 0)
      paperLen <- word16LE body (nameEnd + 1)
      guard (paperLen >= 1 && paperLen <= 5)
      paper <- asciiAt body (nameEnd + 3) (fromIntegral paperLen)
      guard (paper `elem` paperSizes)
      let afterPaper = nameEnd + 3 + fromIntegral paperLen + 1
      pure PageHeader
        { pageHeaderName = name
        , pageHeaderPaper = paper
        , pageHeaderModified = plausibleTime (word32LE body (afterPaper + 4))
        , pageHeaderProperties = []
        }

    plausibleTime raw = do
      stamp <- fromIntegral <$> raw
      -- 1990-01-01 .. 2040-01-01, to reject zeroed or misaligned fields.
      guard (stamp > 631152000 && stamp < 2208988800)
      pure stamp

    fallbackName =
      case [s | (_, s) <- extractStrings (BS.take 100 body) 3, "00_" `isPrefixOf` s || length s > 3] of
        s : _ -> s
        [] -> ""

-- | Title-block field values live in a property table at the tail of the
-- page-header record: a u16 pair count followed by that many
-- (u32 name index, u32 value index) pairs, both indexing the Library
-- string pool.  The table ends where the next record begins.
--
-- The pair count is recovered by trying each candidate and keeping the
-- one whose stored count matches and whose name indices all resolve to
-- non-empty pool entries; property names are never blank.
parsePagePropertyTable
  :: [String] -> BS.ByteString -> Int -> Int -> [(Int, Int)]
parsePagePropertyTable values body lowerBound tableEnd =
  fromMaybe [] (firstJust [tableOf count | count <- [1 .. 255]])
  where
    valueCount = length values

    tableOf count = do
      let start = tableEnd - 8 * count - 2
      guard (start >= lowerBound)
      stored <- word16LE body start
      guard (fromIntegral stored == count)
      traverse (pairAt start) [0 .. count - 1]

    pairAt start i = do
      nameIdx <- fromIntegral <$> word32LE body (start + 2 + 8 * i)
      valueIdx <- fromIntegral <$> word32LE body (start + 6 + 8 * i)
      guard (nameIdx >= 0 && nameIdx < valueCount)
      guard (valueIdx >= 0 && valueIdx < valueCount)
      name <- lookupList values nameIdx
      guard (not (null name))
      pure (nameIdx, valueIdx)

-- | Resolve one page's title-block fields from its property table.
resolveTitleBlock :: [String] -> PageHeader -> TitleBlock
resolveTitleBlock values header = TitleBlock
  { titleBlockTitle = property "Title"
  , titleBlockDocumentNumber = property "Doc"
  , titleBlockRevision = property "RevCode"
  , titleBlockCompany =
      case property "OrgName" of
        "" -> property "Org_Name"
        name -> name
  , titleBlockDate = maybe "" isoDateFromUnix (pageHeaderModified header)
  }
  where
    property wanted = fromMaybe "" $ firstJust
      [ lookupList values valueIdx
      | (nameIdx, valueIdx) <- pageHeaderProperties header
      , lookupList values nameIdx == Just wanted
      ]

-- | Unix `time_t` (UTC) as an ISO-8601 date, which is what KiCad's own
-- date field holds.  The DSN records no time zone.
isoDateFromUnix :: Int -> String
isoDateFromUnix stamp =
  let (y, m, d) = civilFromDays (stamp `div` 86400)
  in padNum 4 y ++ "-" ++ padNum 2 m ++ "-" ++ padNum 2 d
  where
    padNum width n =
      let digits = show n
      in replicate (width - length digits) '0' ++ digits

-- | Days since 1970-01-01 to (year, month, day); Howard Hinnant's
-- civil_from_days.
civilFromDays :: Int -> (Int, Int, Int)
civilFromDays days =
  let z = days + 719468
      era = (if z >= 0 then z else z - 146096) `div` 146097
      doe = z - era * 146097
      yoe = (doe - doe `div` 1460 + doe `div` 36524 - doe `div` 146096) `div` 365
      doy = doe - (365 * yoe + yoe `div` 4 - yoe `div` 100)
      mp = (5 * doy + 2) `div` 153
      d = doy - (153 * mp + 2) `div` 5 + 1
      m = if mp < 10 then mp + 3 else mp - 9
      y = yoe + era * 400
  in (if m <= 2 then y + 1 else y, m, d)

parseNetTable :: BS.ByteString -> Map.Map Int String
parseNetTable body =
  fromMaybe Map.empty $ firstJust $ map tryAnchor $ reverse $ findAll netTableAnchor body
  where
    tryAnchor anchorPos = do
      extraCount <- word16LE body (anchorPos + 12)
      let netCountPos = anchorPos + 14 + fromIntegral extraCount * 4
      netCount <- word16LE body netCountPos
      guard (netCount >= 1 && netCount <= 1000)
      let entries = parseNetEntries (netCountPos + 2) (fromIntegral netCount)
      guard (not (Map.null entries))
      pure entries

    parseNetEntries :: Int -> Int -> Map.Map Int String
    parseNetEntries _ 0 = Map.empty
    parseNetEntries pos count =
      case parseOne pos of
        Just (nextPos, netId, name) ->
          -- Later entries are OrCAD's canonical spelling/alias for a reused ID.
          Map.insertWith
            (\_ laterName -> laterName)
            netId
            name
            (parseNetEntries nextPos (count - 1))
        Nothing -> Map.empty

    parseOne pos = do
      nameLen <- word16LE body pos
      guard (nameLen >= 1 && nameLen <= 50)
      name <- asciiAt body (pos + 2) (fromIntegral nameLen)
      let nulPos = pos + 2 + fromIntegral nameLen
      guard (byteAt body nulPos == Just 0)
      netId <- word32LE body (nulPos + 1)
      pure (nulPos + 5, fromIntegral netId, name)

parseWires :: Map.Map Int String -> BS.ByteString -> [Wire]
parseWires nets body =
  let modern = mapMaybe parseAt (findAll recordMarker body)
  in if null modern
       then mapMaybe parseLegacyAt (findAll legacyWirePrefix body)
       else modern
  where
    legacyWirePrefix = BS.pack [0x14, 0x00, 0x00]

    parseAt idx = do
      subtype <- word32LE body (idx + 16)
      guard (subtype == 0x30)
      netId <- fromIntegral <$> word32LE body (idx + 12)
      x1 <- int32LE body (idx + 20)
      y1 <- int32LE body (idx + 24)
      x2 <- int32LE body (idx + 28)
      y2 <- int32LE body (idx + 32)
      guard (all (\v -> abs v < 5000) [x1, y1, x2, y2])
      pure Wire
        { wireNetId = netId
        , wireNetName = Map.findWithDefault "" netId nets
        , wireX1 = x1
        , wireY1 = y1
        , wireX2 = x2
        , wireY2 = y2
        , wireIsBus = isBusNetName (Map.findWithDefault "" netId nets)
        }

    parseLegacyAt idx = do
      subtype <- word32LE body (idx + 11)
      guard (subtype == 0x30)
      netId <- fromIntegral <$> word32LE body (idx + 7)
      x1 <- int32LE body (idx + 15)
      y1 <- int32LE body (idx + 19)
      x2 <- int32LE body (idx + 23)
      y2 <- int32LE body (idx + 27)
      guard (all (\v -> abs v < 5000) [x1, y1, x2, y2])
      guard (x1 /= x2 || y1 /= y2)
      pure Wire
        { wireNetId = netId
        , wireNetName = Map.findWithDefault "" netId nets
        , wireX1 = x1
        , wireY1 = y1
        , wireX2 = x2
        , wireY2 = y2
        , wireIsBus = False
        }

parseNetAliases :: Map.Map Int String -> BS.ByteString -> [NetLabel]
parseNetAliases nets body = mapMaybe parseAt (findAll recordMarker body)
  where
    canonical = Map.fromList [(map toUpper name, name) | name <- Map.elems nets]

    parseAt idx = do
      subtype <- word32LE body (idx + 16)
      firstCoord <- word32LE body (idx + 20)
      guard (subtype == 0x30 && firstCoord == 0)
      nameLenWord <- word16LE body (idx + 28)
      let nameLen = fromIntegral nameLenWord
      guard (nameLen >= 1 && nameLen <= 100)
      name <- asciiAt body (idx + 30) nameLen
      xWord <- word32LE body (idx + 8)
      yWord <- word32LE body (idx + 12)
      x <- maybeWord32ToInt xWord
      y <- maybeWord32ToInt yWord
      guard (x < 5000 && y < 5000)
      pure NetLabel
        { netLabelGlobal = False
        , netLabelName = Map.findWithDefault name (map toUpper name) canonical
        , netLabelX = x
        , netLabelY = y
        , netLabelAngle = 0
        }

isBusNetName :: String -> Bool
isBusNetName name = maybe False (const True) (busMemberPrefix name)

busMemberPrefix :: String -> Maybe String
busMemberPrefix = go []
  where
    go _ [] = Nothing
    go prefix ('[':rest) = do
      let (high, afterHigh) = span isDigit rest
      guard (not (null high))
      afterDots <- stripStringPrefix ".." afterHigh
      let (low, afterLow) = span isDigit afterDots
      guard (not (null low))
      case afterLow of
        ']':_ -> pure ()
        _ -> Nothing
      pure (reverse prefix)
    go prefix (char:rest) = go (char:prefix) rest

sanitizePageName :: String -> String
sanitizePageName = trimUnderscores . collapseUnderscores . map sanitize
  where
    sanitize char
      | isAlphaNum char || char `elem` ("_.-" :: String) = char
      | otherwise = '_'

    collapseUnderscores [] = []
    collapseUnderscores ('_':'_':rest) = collapseUnderscores ('_':rest)
    collapseUnderscores (char:rest) = char : collapseUnderscores rest

    trimUnderscores = reverse . dropWhile (== '_') . reverse . dropWhile (== '_')

canonicalizePageNetNames :: [Page] -> [Page]
canonicalizePageNetNames pages = map canonicalizePage pages
  where
    spellings = foldl addPageSpellings Map.empty pages
    canonical = Map.map mostFrequentSpelling spellings

    addPageSpellings current page = foldl addSpelling current
      [ name
      | (_, name) <- Map.toAscList (pageNets page)
      , not (null name)
      ]

    addSpelling current name =
      Map.insertWith
        (\new old -> old ++ new)
        (map toUpper name)
        [name]
        current

    mostFrequentSpelling names = fst $ foldl choose ("", -1 :: Int) (unique names)
      where
        choose best@(_, bestCount) candidate =
          let candidateCount = length (filter (== candidate) names)
          in if candidateCount > bestCount
               then (candidate, candidateCount)
               else best

    canonicalName name =
      Map.findWithDefault name (map toUpper name) canonical

    canonicalizePage page = page
      { pageNets = Map.map canonicalName (pageNets page)
      , pageWires =
          [ wire { wireNetName = canonicalName (wireNetName wire) }
          | wire <- pageWires page
          ]
      , pageNetAliases =
          [ alias { netLabelName = canonicalName (netLabelName alias) }
          | alias <- pageNetAliases page
          ]
      , pageOffPageConnectors =
          [ connector { offPageNetName = canonicalName (offPageNetName connector) }
          | connector <- pageOffPageConnectors page
          ]
      , pageComponents = map canonicalizeComponent (pageComponents page)
      , pagePowerSymbols =
          [ symbol { powerNetName = canonicalName (powerNetName symbol) }
          | symbol <- pagePowerSymbols page
          ]
      }

    canonicalizeComponent component = component
      { compPagePins =
          [ pin { pagePinNetName = canonicalName (pagePinNetName pin) }
          | pin <- compPagePins component
          ]
      }

assignPowerReferences :: [Page] -> Map.Map (FilePath, Int) String
assignPowerReferences pages = Map.fromList (zip keys references)
  where
    keys =
      [ (pageStreamName page, powerIndex)
      | page <- pages
      , powerIndex <- [1 .. length (pagePowerSymbols page)]
      ]
    references = map powerReferenceName [1 :: Int ..]

-- Power symbols get project-wide sequential references (#PWR01, #PWR02, ...).
powerReferenceName :: Int -> String
powerReferenceName index =
  let rendered = show index
  in "#PWR" ++ replicate (max 0 (2 - length rendered)) '0' ++ rendered

wirePoint1 :: Wire -> (Int, Int)
wirePoint1 wire = (wireX1 wire, wireY1 wire)

wirePoint2 :: Wire -> (Int, Int)
wirePoint2 wire = (wireX2 wire, wireY2 wire)

pointOnWire :: (Int, Int) -> Wire -> Bool
pointOnWire (px, py) wire =
  let (x1, y1) = wirePoint1 wire
      (x2, y2) = wirePoint2 wire
      cross = (px - x1) * (y2 - y1) - (py - y1) * (x2 - x1)
  in cross == 0
     && min x1 x2 <= px && px <= max x1 x2
     && min y1 y2 <= py && py <= max y1 y2

data WireSpatialIndex = WireSpatialIndex
  { horizontalWires :: Map.Map Int [(Int, Wire)]
  , verticalWires :: Map.Map Int [(Int, Wire)]
  , diagonalWires :: [(Int, Wire)]
  }

buildWireSpatialIndex :: [(Int, Wire)] -> WireSpatialIndex
buildWireSpatialIndex = foldl addWire (WireSpatialIndex Map.empty Map.empty [])
  where
    addWire index indexed@(_, wire)
      | wireY1 wire == wireY2 wire = index
          { horizontalWires = Map.insertWith (++)
              (wireY1 wire) [indexed] (horizontalWires index)
          }
      | wireX1 wire == wireX2 wire = index
          { verticalWires = Map.insertWith (++)
              (wireX1 wire) [indexed] (verticalWires index)
          }
      | otherwise = index { diagonalWires = indexed : diagonalWires index }

indexedWiresAt :: (Int, Int) -> WireSpatialIndex -> [(Int, Wire)]
indexedWiresAt point@(x, y) index =
  filter (pointOnWire point . snd) $
    Map.findWithDefault [] y (horizontalWires index)
    ++ Map.findWithDefault [] x (verticalWires index)
    ++ diagonalWires index

wireComponents :: [Wire] -> [[Wire]]
wireComponents wires = collectComponents allIndices
  where
    indexed = zip [(0 :: Int)..] wires
    wireMap = Map.fromList indexed
    spatial = buildWireSpatialIndex indexed
    allIndices = Set.fromList (map fst indexed)
    adjacency = foldl addConnections initialAdjacency indexed
    initialAdjacency = Map.fromList [(idx, Set.empty) | (idx, _) <- indexed]

    addConnections current (idx, wire) =
      foldl (connectAt idx) current [wirePoint1 wire, wirePoint2 wire]

    connectAt idx current point = foldl (connect idx) current
      [ otherIdx
      | (otherIdx, _) <- indexedWiresAt point spatial
      , otherIdx /= idx
      ]

    connect left current right =
      Map.insertWith Set.union left (Set.singleton right) $
        Map.insertWith Set.union right (Set.singleton left) current

    collectComponents remaining =
      case Set.minView remaining of
        Nothing -> []
        Just (start, _) ->
          let members = reachable Set.empty [start]
              component = mapMaybe (`Map.lookup` wireMap) (Set.toAscList members)
          in component : collectComponents (Set.difference remaining members)

    reachable visited [] = visited
    reachable visited (current:pending)
      | Set.member current visited = reachable visited pending
      | otherwise =
          let neighbours = Set.toList $ Map.findWithDefault Set.empty current adjacency
          in reachable (Set.insert current visited) (neighbours ++ pending)

wireDirectionsAt :: (Int, Int) -> [Wire] -> [(Int, Int)]
wireDirectionsAt point wires = unique
  [ normalizeDirection (x - fst point, y - snd point)
  | wire <- wires
  , pointOnWire point wire
  , (x, y) <- [wirePoint1 wire, wirePoint2 wire]
  , (x, y) /= point
  ]
  where
    normalizeDirection (dx, dy) =
      let divisor = gcd (abs dx) (abs dy)
      in if divisor == 0 then (0, 0) else (dx `div` divisor, dy `div` divisor)

computeJunctions :: [Wire] -> [(Int, Int)]
computeJunctions wires = sortOn id $ Set.toList $ Set.fromList
  [ point
  | netWires <- Map.elems groupedByNet
  , let spatial = buildWireSpatialIndex (zip [(0 :: Int)..] netWires)
  , point <- unique [p | wire <- netWires, p <- [wirePoint1 wire, wirePoint2 wire]]
  , let touching = map snd (indexedWiresAt point spatial)
  , length (wireDirectionsAt point touching) >= 3
  ]
  where
    groupedByNet = foldl
      (\groups wire ->
        Map.insertWith (\new old -> old ++ new)
          (wireNetId wire) [wire] groups)
      Map.empty
      wires

placeWireLabels :: Set.Set String -> [Wire] -> [NetLabel]
placeWireLabels powerNets wires =
  concat
    [ concatMap (labelsForComponent name) (wireComponents netWires)
    | (name, netWires) <- Map.toList groupedByName
    , not (Set.member name powerNets)
    ]
  where
    groupedByName = foldl addWire Map.empty wires

    addWire groups wire
      | null (wireNetName wire) = groups
      | otherwise = Map.insertWith (\new old -> old ++ new)
          (wireNetName wire) [wire] groups

    labelsForComponent name component =
      [ let outwardAngle = wireAngleAt point component
            angle = (outwardAngle + 180) `mod` 360
        in NetLabel False name (fst point) (snd point) angle
      | point <- freeEndpoints component
      ]

    freeEndpoints component = Map.keys $ Map.filter (== 1) endpointCounts
      where
        endpointCounts = foldl
          (\counts point -> Map.insertWith (+) point (1 :: Int) counts)
          Map.empty
          [ point
          | wire <- component
          , point <- [wirePoint1 wire, wirePoint2 wire]
          ]

    wireAngleAt point component =
      case [other | wire <- component, Just other <- [otherEndpoint point wire]] of
        (otherX, otherY) : _ ->
          let dx = fst point - otherX
              dy = snd point - otherY
          in if abs dx >= abs dy
               then if dx > 0 then 0 else 180
               else if dy > 0 then 270 else 90
        [] -> 0

    otherEndpoint point wire
      | wirePoint1 wire == point = Just (wirePoint2 wire)
      | wirePoint2 wire == point = Just (wirePoint1 wire)
      | otherwise = Nothing

data BusEntry = BusEntry Int Int Int Int
  deriving Show

synthesizeBusEntries :: [Wire] -> [Wire] -> ([BusEntry], Set.Set (Int, Int))
synthesizeBusEntries busWires regularWires =
  let entries = mapMaybe entryForWire regularWires
  in ( entries
     , Set.fromList [(x + dx, y + dy) | BusEntry x y dx dy <- entries]
     )
  where
    busPoints = Map.fromListWith Set.union
      [ (wireNetName wire, Set.fromList [wirePoint1 wire, wirePoint2 wire])
      | wire <- busWires
      , not (null (wireNetName wire))
      ]
    busPrefixes =
      [ (busName, prefix)
      | busName <- Map.keys busPoints
      , Just prefix <- [busMemberPrefix busName]
      ]

    isMemberOf netName busName =
      case lookup busName busPrefixes of
        Nothing -> False
        Just prefix ->
          let suffix = drop (length prefix) netName
          in prefix `isPrefixOf` netName && not (null suffix) && all isDigit suffix

    entryForWire wire = do
      busName <- firstJust
        [ if isMemberOf (wireNetName wire) name then Just name else Nothing
        | (name, _) <- busPrefixes
        ]
      points <- Map.lookup busName busPoints
      firstJust
        [ busEntryAt endpoint points
        | endpoint <- [wirePoint1 wire, wirePoint2 wire]
        ]

    -- A bus entry is the diagonal stub between a member wire's endpoint and the
    -- bus it taps.  Every candidate is one grid step away on both axes, so they
    -- are all equidistant; ordering by (dy, dx) just picks one deterministically.
    busEntryAt (x, y) points =
      case sortOn (\(dx, dy) -> (dy, dx))
        [ (dx, dy)
        | (busX, busY) <- Set.toList points
        , let dx = busX - x
              dy = busY - y
        , abs dx == 10 && abs dy == 10
        ] of
        (dx, dy) : _ -> Just (BusEntry x y dx dy)
        [] -> Nothing

explicitAliasCovers :: [Wire] -> [NetLabel] -> NetLabel -> Bool
explicitAliasCovers wires aliases generated = any covered matchingAliases
  where
    matchingAliases =
      [ alias
      | alias <- aliases
      , netLabelName alias == netLabelName generated
      ]
    matchingWires =
      [ wire
      | wire <- wires
      , wireNetName wire == netLabelName generated
      ]
    generatedPoint = (netLabelX generated, netLabelY generated)

    covered alias = any componentContainsBoth (wireComponents matchingWires)
      where
        aliasPoint = (netLabelX alias, netLabelY alias)
        componentContainsBoth component =
          any (pointOnWire generatedPoint) component
          && any (pointOnWire aliasPoint) component

parseComponents :: [String] -> Map.Map Int String -> BS.ByteString -> [Component]
parseComponents libraryValues nets body =
  mapMaybe parseIndexedMatch (zip [(0 :: Int)..] matches)
  where
    matches = findCellMatches body

    parseIndexedMatch (matchIndex, (_, cellEnd, cellName)) = do
      rawX <- int16LE body (cellEnd + 6)
      rawY <- int16LE body (cellEnd + 8)
      let locX = fromMaybe rawX (int16LE body (cellEnd + 12))
          locY = fromMaybe rawY (int16LE body (cellEnd + 14))
          orient = case (byteAt body (cellEnd + 16), byteAt body (cellEnd + 17)) of
            (Just 0x30, Just b) -> fromIntegral b
            _ -> 0
          search = BS.take 300 (BS.drop (cellEnd + 16) body)
          searchEnd = case drop (matchIndex + 1) matches of
            (nextStart, _, _) : _ -> min nextStart (cellEnd + 20000)
            [] -> min (BS.length body) (cellEnd + 20000)
          displayFields = parseComponentDisplayFields body cellEnd searchEnd
      (refName, valueIdx) <- findReference search
      let componentValue = case valueIdx >>= lookupList libraryValues of
            Just value | not (null value) -> value
            _ -> cellName
          fieldNamed name = firstJust
            [ if lookupList libraryValues (displayPropertyIndex field) == Just name
                then Just field
                else Nothing
            | field <- displayFields
            ]
      pure Component
        { compCell = cellName
        , compRef = refName
        , compValue = componentValue
        , compX = rawX
        , compY = rawY
        , compOrient = orient
        , compPagePins = parsePagePins nets body cellEnd searchEnd
        , compLocX = locX
        , compLocY = locY
        , compRefField = fieldNamed "Part Reference" `orElse` listAt displayFields 0
        , compValueField = fieldNamed "Value" `orElse` listAt displayFields 1
        , compOriginX = Nothing
        , compOriginY = Nothing
        }

parseComponentDisplayFields
  :: BS.ByteString -> Int -> Int -> [DisplayField]
parseComponentDisplayFields body cellEnd searchEnd =
  mapMaybe parseAt markerOffsets
  where
    recordEnd = min (cellEnd + 200) searchEnd
    markerOffsets = filter (< recordEnd) (findAllFrom recordMarker cellEnd body)

    parseAt idx = do
      zeros <- word32LE body (idx + 4)
      propertyIndex <- word32LE body (idx + 8)
      guard (zeros == 0 && propertyIndex < 0x100)
      x <- int16LE body (idx + 12)
      y <- int16LE body (idx + 14)
      rotFont <- word16LE body (idx + 16)
      let angle = fromIntegral ((rotFont `div` 0x4000) .&. 0x03) * 90
      pure DisplayField
        { displayPropertyIndex = fromIntegral propertyIndex
        , displayOffsetX = x
        , displayOffsetY = y
        , displayTextAngle = angle
        }

parsePagePins
  :: Map.Map Int String -> BS.ByteString -> Int -> Int -> [PagePin]
parsePagePins nets body cellEnd searchEnd =
  let modern = go markerOffsets skipCount Nothing []
  in if null modern then legacyPins else modern
  where
    markerOffsets = filter (< searchEnd) (findAllFrom recordMarker cellEnd body)
    skipCount :: Int
    skipCount = maybe 0 fromIntegral (word16LE body (cellEnd + 20))
    pinStrideMax = 50
    legacyPinPrefix = BS.pack [0x10, 0x00, 0x00]
    legacyPins = mapMaybe parseLegacyPin $
      filter (< searchEnd) (findAllFrom legacyPinPrefix cellEnd body)

    go [] _ _ pins = reverse pins
    go (idx:rest) skipped lastAccepted pins
      | skipped > 0 = go rest (skipped - 1) lastAccepted pins
      | maybe False (\lastIdx -> idx - lastIdx > pinStrideMax) lastAccepted =
          reverse pins
      | otherwise =
          case parsePin idx of
            Just pin -> go rest 0 (Just idx) (pin:pins)
            Nothing -> go rest 0 lastAccepted pins

    parsePin idx = do
      zeros <- word32LE body (idx + 4)
      guard (zeros == 0)
      pinNumber <- fromIntegral <$> word16LE body (idx + 8)
      guard (pinNumber >= 1 && pinNumber <= 500)
      x <- int16LE body (idx + 10)
      y <- int16LE body (idx + 12)
      guard (x /= 0 || y /= 0)
      let netId = maybe 0 fromIntegral (word32LE body (idx + 18))
          netName = Map.findWithDefault "" netId nets
      pure PagePin
        { pagePinNumber = pinNumber
        , pagePinX = x
        , pagePinY = y
        , pagePinNetId = netId
        , pagePinNetName = netName
        }

    parseLegacyPin idx = do
      pinNumber <- fromIntegral <$> word16LE body (idx + 3)
      guard (pinNumber >= 1 && pinNumber <= 500)
      x <- fromIntegral <$> word16LE body (idx + 5)
      y <- fromIntegral <$> word16LE body (idx + 7)
      guard (x > 0 && x < 5000 && y > 0 && y < 5000)
      pure PagePin
        { pagePinNumber = pinNumber
        , pagePinX = x
        , pagePinY = y
        , pagePinNetId = 0
        , pagePinNetName = ""
        }

parseOffPageConnectors :: BS.ByteString -> [OffPageConnector]
parseOffPageConnectors body = mapMaybe parseAt (findAll recordMarker body)
  where
    parseAt idx = do
      zeros <- word32LE body (idx + 4)
      guard (zeros == 0)
      nameLen <- word16LE body (idx + 16)
      guard (nameLen >= 1 && nameLen <= 50)
      let nameStart = idx + 18
          nameEnd = nameStart + fromIntegral nameLen
      name <- asciiAt body nameStart (fromIntegral nameLen)
      guard ("OFFPAGE" `isInfixOf` map toUpper name)
      guard (byteAt body nameEnd == Just 0)
      let afterNull = nameEnd + 1
      locY <- int16LE body (afterNull + 4)
      locX <- int16LE body (afterNull + 6)
      y2 <- int16LE body (afterNull + 8)
      x2 <- int16LE body (afterNull + 10)
      x1 <- int16LE body (afterNull + 12)
      y1 <- int16LE body (afterNull + 14)
      orient <- fromIntegral <$> word16LE body (afterNull + 16)
      propertyCount <- word16LE body (afterNull + 20)
      guard (propertyCount <= 8)
      guard (all (\value -> abs value < 5000) [locX, locY, x1, y1, x2, y2])
      guard (x1 /= x2 || y1 /= y2)
      let ((hotX, hotY), angle) = offPageHotpoint name (x1, y1, x2, y2) orient
      pure OffPageConnector
        { offPageNetName = ""
        , offPageX = hotX
        , offPageY = hotY
        , offPageAngle = angle
        , offPageMatched = False
        }

offPageHotpoint :: String -> (Int, Int, Int, Int) -> Int -> ((Int, Int), Int)
offPageHotpoint name (rawX1, rawY1, rawX2, rawY2) orient =
  let upper = map toUpper name
      pointsRight = any (`isSuffixOf` upper) ["-R", "/R", "-IN"]
      orientation = (orient `div` 256) .&. 0x07
      initialX :: Int
      initialX = if pointsRight then 1 else -1
      mirroredX = if orientation .&. 0x04 /= 0 then negate initialX else initialX
      (directionX, directionY) = case orientation .&. 0x03 of
        1 -> (0, negate mirroredX)
        2 -> (negate mirroredX, 0)
        3 -> (0, mirroredX)
        _ -> (mirroredX, 0)
      x1 = min rawX1 rawX2
      x2 = max rawX1 rawX2
      y1 = min rawY1 rawY2
      y2 = max rawY1 rawY2
      midX = (x1 + x2) `div` 2
      midY = (y1 + y2) `div` 2
  in if directionX < 0
       then ((x1, midY), 0)
       else if directionX > 0
         then ((x2, midY), 180)
         else if directionY < 0
           then ((midX, y1), 270)
           else ((midX, y2), 90)

resolveOffPageConnectors
  :: [Wire] -> [Component] -> [NetLabel] -> [OffPageConnector]
  -> [OffPageConnector]
resolveOffPageConnectors wires components aliases = map resolve
  where
    pinNets = Map.fromList
      [ ((pagePinX pin, pagePinY pin), pagePinNetName pin)
      | component <- components
      , pin <- compPagePins component
      , not (null (pagePinNetName pin))
      ]
    aliasNets = Map.fromList
      [ ((netLabelX alias, netLabelY alias), netLabelName alias)
      | alias <- aliases
      , not (null (netLabelName alias))
      ]

    resolve connector =
      let point = (offPageX connector, offPageY connector)
          endpointMatches =
            [ wireNetName wire
            | wire <- wires
            , not (null (wireNetName wire))
            , point == wirePoint1 wire || point == wirePoint2 wire
            ]
          segmentMatches =
            [ wireNetName wire
            | wire <- wires
            , not (null (wireNetName wire))
            , pointOnWire point wire
            ]
          match = listAt (reverse endpointMatches) 0
            `orElse` Map.lookup point pinNets
            `orElse` Map.lookup point aliasNets
            `orElse` listAt (reverse segmentMatches) 0
      in case match of
           Just netName -> connector
             { offPageNetName = netName
             , offPageMatched = True
             }
           Nothing -> connector

parsePowerSymbols :: BS.ByteString -> [PowerSymbol]
parsePowerSymbols body =
  let modern = mapMaybe parseAt (findAll recordMarker body)
  in if null modern
       then mapMaybe parseLegacyAt (findAll legacyGlobalPrefix body)
       else modern
  where
    legacyGlobalPrefix = BS.pack [0x25, 0x00, 0x00, 0x32, 0x00, 0x27]

    parseAt idx = do
      zeros <- word32LE body (idx + 4)
      guard (zeros == 0)
      nameLen <- word16LE body (idx + 16)
      guard (nameLen >= 1 && nameLen <= 30)
      let nameStart = idx + 18
          nameEnd = nameStart + fromIntegral nameLen
      name <- asciiAt body nameStart (fromIntegral nameLen)
      guard (byteAt body nameEnd == Just 0)
      style <- powerRecordStyle name
      let afterNull = nameEnd + 1
      coords <- readPowerCoords (afterNull + 4)
      orient <- fromIntegral <$> word16LE body (afterNull + 16)
      let (hotX, hotY) = transformPowerAnchor style coords orient
          (valueOffset, valueRotation) = parsePowerDisplay afterNull
      pure PowerSymbol
        { powerNetName = name
        , powerStyle = style
        , powerCoords = coords
        , powerOrient = orient
        , powerHotX = hotX
        , powerHotY = hotY
        , powerMatched = False
        , powerValueOffset = valueOffset
        , powerValueRotation = valueRotation
        }

    parseLegacyAt idx = do
      x <- fromIntegral <$> word16LE body (idx + 27)
      y <- fromIntegral <$> word16LE body (idx + 29)
      guard (x > 0 && x < 5000 && y > 0 && y < 5000)
      pure PowerSymbol
        { powerNetName = "0"
        , powerStyle = PowerGround
        , powerCoords = (0, 0, 0, 0, x, y)
        , powerOrient = 0
        , powerHotX = x + 10
        , powerHotY = y
        , powerMatched = True
        , powerValueOffset = Nothing
        , powerValueRotation = Nothing
        }

    readPowerCoords off = do
      a <- int16LE body off
      b <- int16LE body (off + 2)
      c <- int16LE body (off + 4)
      d <- int16LE body (off + 6)
      e <- int16LE body (off + 8)
      f <- int16LE body (off + 10)
      pure (a, b, c, d, e, f)

    parsePowerDisplay afterNull =
      case word16LE body (afterNull + 20) of
        Just count | count >= 1 && count <= 8 ->
          case findSubFrom recordMarker (afterNull + 22) body of
            Just propAt | propAt < afterNull + 102 ->
              case (int16LE body (propAt + 12), int16LE body (propAt + 14),
                    word16LE body (propAt + 16)) of
                (Just offX, Just offY, Just rotFont) ->
                  let rotation = fromIntegral ((rotFont `div` 0x4000) .&. 0x03) * 90
                  in (Just (offX, offY), Just rotation)
                _ -> (Nothing, Nothing)
            _ -> (Nothing, Nothing)
        _ -> (Nothing, Nothing)


powerRecordStyle :: String -> Maybe PowerStyle
powerRecordStyle name
  | isGroundPowerName upper || upper `elem` ["GND_POWER", "AG"] =
      Just PowerGround
  | upper `elem` ["VCC", "VCC_CIRCLE"] = Just PowerCircle
  | upper == "VCC_BAR" = Just PowerRail
  | otherwise = Nothing
  where
    upper = map toUpper name

isGroundPowerName :: String -> Bool
isGroundPowerName name =
  let upper = map toUpper name
  in upper `elem`
       [ "GND", "AGND", "PGND", "VSS", "DGND", "SGND", "ADAVSS", "GROUND" ]
     || "GND" `isPrefixOf` upper
     || "GROUND" `isPrefixOf` upper
     || reverse "_VSS" `isPrefixOf` reverse upper

transformPowerAnchor
  :: PowerStyle -> (Int, Int, Int, Int, Int, Int) -> Int -> (Int, Int)
transformPowerAnchor style (_, _, _, _, x1, y1) orient =
  case (orient `div` 256) .&. 0x03 of
    0 -> (x1 + anchorX, y1 + anchorY)
    1 -> (x1 + anchorY, y1 + width - anchorX)
    2 -> (x1 + width - anchorX, y1 + height - anchorY)
    _ -> (x1 + height - anchorY, y1 + anchorX)
  where
    anchorX = 10
    anchorY = if style == PowerGround then 0 else 10
    width = 20
    height = 10

resolvePowerSymbols :: [Wire] -> [Component] -> [PowerSymbol] -> [PowerSymbol]
resolvePowerSymbols wires components = map resolve
  where
    pinNets = Map.fromList
      [ ((pagePinX pin, pagePinY pin), (pagePinNetId pin, pagePinNetName pin))
      | component <- components
      , pin <- compPagePins component
      , not (null (pagePinNetName pin))
      ]

    resolve symbol =
      let point = (powerHotX symbol, powerHotY symbol)
          endpointMatches =
            [ (wireNetId wire, wireNetName wire)
            | wire <- wires
            , not (null (wireNetName wire))
            , point == wirePoint1 wire || point == wirePoint2 wire
            ]
          segmentMatches =
            [ (wireNetId wire, wireNetName wire)
            | wire <- wires
            , not (null (wireNetName wire))
            , pointOnWire point wire
            ]
          -- OrCAD can store multiple net records at one electrical endpoint.
          -- Its later record supplies the effective net name.
          match = case reverse endpointMatches of
            firstMatch : _ -> Just firstMatch
            [] -> Map.lookup point pinNets `orElse` listAt (reverse segmentMatches) 0
      in case match of
           Just (_, netName) -> symbol
             { powerNetName = netName
             , powerStyle =
                 if isGroundPowerName netName then PowerGround else powerStyle symbol
             , powerMatched = True
             }
           Nothing -> symbol

parsePageTexts :: String -> BS.ByteString -> [PageText]
parsePageTexts paper body = mapMaybe parseAt (findAll textRecordType body)
  where
    (pageWidth, pageHeight) = orcadPageSize paper
    titleX = pageWidth - 300
    titleY = pageHeight - 150

    -- Signed, like the graphic records: reading these as unsigned turned a
    -- negative coordinate into ~4 billion, which the bounds guard then dropped.
    parseAt idx = do
      x1 <- int32LE body (idx + 12)
      y1 <- int32LE body (idx + 16)
      x2 <- int32LE body (idx + 20)
      y2 <- int32LE body (idx + 24)
      x3 <- int32LE body (idx + 28)
      y3 <- int32LE body (idx + 32)
      guard (all ((<= 30000) . abs) [x1, y1, x2, y2, x3, y3])
      guard (not (x1 > titleX && y1 > titleY))
      styleId <- fromIntegral <$> word16LE body (idx + 36)
      textLen <- fromIntegral <$> word16LE body (idx + 40)
      guard (textLen >= 1 && textLen <= 2000)
      let textBytes = BS.take textLen (BS.drop (idx + 42) body)
      guard (BS.length textBytes == textLen)
      guard (BS.all isPageTextByte textBytes)
      pure PageText
        { pageTextValue = BSC.unpack textBytes
        , pageTextX1 = x1
        , pageTextY1 = y1
        , pageTextX2 = x2
        , pageTextY2 = y2
        , pageTextStyleId = styleId
        , pageTextColor = pageRecordColor body (idx - 18)
        }

    isPageTextByte byte = isPrintableAscii byte || byte `elem` [9, 10, 13]

parsePageGraphics :: String -> BS.ByteString -> [PageGraphic]
parsePageGraphics paper body = mapMaybe parseAt (findAll recordMarker body)
  where
    (pageWidth, pageHeight) = orcadPageSize paper
    titleX = pageWidth - 300
    titleY = pageHeight - 150
    inTitleBlock x y = x > titleX && y > titleY

    parseAt idx =
      let tag = BS.take 6 (BS.drop (idx + 18) body)
          color = pageRecordColor body idx
      in if tag == pagePolygonTag
           then parsePolygon idx color
           else if tag `elem` [pageRectTag, pageLineTag, pageEllipseTag]
             then parseBoxGraphic idx tag color
             else Nothing

    parseBoxGraphic idx tag color = do
      x1 <- int32LE body (idx + 30)
      y1 <- int32LE body (idx + 34)
      x2 <- int32LE body (idx + 38)
      y2 <- int32LE body (idx + 42)
      guard (all ((< 30000) . abs) [x1, y1, x2, y2])
      guard (not (inTitleBlock x1 y1 && inTitleBlock x2 y2))
      let style
            | tag == pageLineTag = GraphicStyle color 0.15 "default" "none"
            | otherwise = parseGraphicStyle idx color
      pure $ if tag == pageRectTag
        then PageRectangle style x1 y1 x2 y2
        else if tag == pageEllipseTag
          then PageEllipse style x1 y1 x2 y2
          else PageLine style x1 y1 x2 y2

    parseGraphicStyle idx color =
      let lineStyle = fromMaybe 0 (word32LE body (idx + 46))
          lineWidth = fromMaybe 3 (word32LE body (idx + 50))
          fillStyle = fromMaybe 1 (word32LE body (idx + 54))
          strokeType = if lineStyle == 1 then "dash" else "default"
          width = case lineWidth of
            1 -> 0.30
            2 -> 0.50
            _ -> 0.15
          fillType = case fillStyle of
            0 -> "color"
            2 -> "hatch"
            _ -> "none"
      in GraphicStyle color width strokeType fillType

    parsePolygon idx color = do
      count <- fromIntegral <$> word16LE body (idx + 46)
      guard (count >= 3 && count <= 64)
      points <- mapM (readPoint idx) [0 .. count - 1]
      let collapsed = collapseAdjacent points
          openPoints = case collapsed of
            [] -> []
            firstPoint : _
              | last collapsed == firstPoint -> init collapsed
              | otherwise -> collapsed
      guard (length openPoints >= 3)
      guard (not (all (uncurry inTitleBlock) openPoints))
      fillStyle <- word32LE body (idx + 38)
      let fillType = if fillStyle == 0 then "color" else "none"
          style = GraphicStyle color 0.15 "default" fillType
      pure (PagePolygon style openPoints)

    readPoint idx pointIndex = do
      y <- fromIntegral <$> word16LE body (idx + 48 + pointIndex * 4)
      x <- fromIntegral <$> word16LE body (idx + 50 + pointIndex * 4)
      pure (x, y)

    collapseAdjacent = foldr addPoint []
    addPoint point points@(nextPoint:_)
      | point == nextPoint = points
    addPoint point points = point : points

parseLibraryTextStyles :: BS.ByteString -> [TextStyle]
parseLibraryTextStyles body = go 0
  where
    go idx
      | idx + 60 > BS.length body = []
      | isStyleStart idx = case parseAt idx of
          Just style -> style : go (idx + 60)
          Nothing -> go (idx + 1)
      | otherwise = go (idx + 1)

    isStyleStart idx =
      case [byteAt body (idx + offset) | offset <- [0..3]] of
        [Just b0, Just 0xff, Just 0xff, Just 0xff] -> b0 >= 0x80
        _ -> False

    parseAt idx = do
      tag <- int32LE body idx
      escapement <- int32LE body (idx + 8)
      weight <- fromIntegral <$> word32LE body (idx + 16)
      italic <- (== 0xff) <$> byteAt body (idx + 20)
      let face = asciiPrefixAt body (idx + 28) 30
      pure TextStyle
        { textStyleTag = tag
        , textStyleWeight = weight
        , textStyleItalic = italic
        , textStyleEscapement = escapement
        , textStyleFace = face
        }

-- | Raw font face names carrying high bytes.  Mirrors the 60-byte style-record
-- stride of `parseLibraryTextStyles`, but keeps the bytes: the face name is the
-- one place a design reliably names its own script.
libraryFaceNameBytes :: BS.ByteString -> [BS.ByteString]
libraryFaceNameBytes body = unique (go 0)
  where
    go idx
      | idx + 60 > BS.length body = []
      | isStyleStart idx =
          let name = BS.takeWhile (/= 0) (BS.take 30 (BS.drop (idx + 28) body))
          in [name | BS.any (>= 0x80) name] ++ go (idx + 60)
      | otherwise = go (idx + 1)

    isStyleStart idx =
      case [byteAt body (idx + offset) | offset <- [0 .. 3]] of
        [Just b0, Just 0xff, Just 0xff, Just 0xff] -> b0 >= 0x80
        _ -> False

parseLibraryValueStrings :: SourceEncoding -> BS.ByteString -> [String]
parseLibraryValueStrings enc =
  map (decodeLibraryString enc) . libraryRawStrings

libraryRawStrings :: BS.ByteString -> [BS.ByteString]
libraryRawStrings body = fromMaybe [] $ do
  textFontCount <- fromIntegral <$> word16LE body 48
  let afterFonts = 50 + max 0 (textFontCount - 1) * 60
  extraCount <- fromIntegral <$> word16LE body afterFonts
  let mappingsStart = afterFonts + 2 + extraCount * 2 + 8
  (afterMappings, _) <- readLengthStrings body mappingsStart 8
  let stringCountAt = afterMappings + 156
  count32 <- word32LE body stringCountAt
  let stringCount = fromIntegral count32 :: Int
  -- The count is a plain u32.  Reading it as a u16 (as an earlier
  -- revision did for counts above 10000) shifts every pool index by one
  -- and silently drops the whole table on large designs, because the
  -- sanity cap then rejects it.
  guard (stringCount >= 0 && stringCount <= 200000)
  snd <$> readLengthStrings body (stringCountAt + 4) stringCount

-- Kept as raw bytes: the pool's encoding is not known until
-- `detectSourceEncoding` has seen these strings.
readLengthStrings
  :: BS.ByteString -> Int -> Int -> Maybe (Int, [BS.ByteString])
readLengthStrings body = go []
  where
    go values pos 0 = Just (pos, reverse values)
    go values pos remaining = do
      stringLen <- fromIntegral <$> word16LE body pos
      guard (stringLen >= 0 && pos + 2 + stringLen <= BS.length body)
      let stringStart = pos + 2
          raw = BS.take stringLen (BS.drop stringStart body)
          afterString = stringStart + stringLen
          nextPos = if byteAt body afterString == Just 0
              then afterString + 1
              else afterString
      go (raw : values) nextPos (remaining - 1)

orcadPageSize :: String -> (Int, Int)
orcadPageSize paper = Map.findWithDefault (1654, 1170) paper $ Map.fromList
  [ ("A4", (1170, 827)), ("A3", (1654, 1170)), ("A2", (2340, 1654))
  , ("A1", (3311, 2340)), ("A0", (4681, 3311)), ("A", (1100, 850))
  , ("B", (1700, 1100)), ("C", (2200, 1700)), ("D", (3400, 2200))
  , ("E", (4400, 3400))
  ]

pageRecordColor :: BS.ByteString -> Int -> Rgba
pageRecordColor body markerAt =
  let colorIndex = maybe 48 fromIntegral (byteAt body (markerAt - 37))
  in orcadPalette !! min 48 colorIndex

orcadPalette :: [Rgba]
orcadPalette =
  [ Rgba 255 128 128 1, Rgba 255 255 128 1, Rgba 128 255 128 1
  , Rgba 0 255 128 1, Rgba 128 255 255 1, Rgba 0 128 255 1
  , Rgba 255 128 192 1, Rgba 255 128 255 1, Rgba 255 0 0 1
  , Rgba 255 255 0 1, Rgba 128 255 0 1, Rgba 0 255 64 1
  , Rgba 0 255 255 1, Rgba 0 128 192 1, Rgba 128 128 192 1
  , Rgba 255 0 255 1, Rgba 128 64 64 1, Rgba 255 128 64 1
  , Rgba 0 255 0 1, Rgba 0 128 128 1, Rgba 0 64 128 1
  , Rgba 128 128 255 1, Rgba 128 0 64 1, Rgba 255 0 128 1
  , Rgba 128 0 0 1, Rgba 255 128 0 1, Rgba 0 128 0 1
  , Rgba 0 128 64 1, Rgba 0 0 255 1, Rgba 0 0 160 1
  , Rgba 128 0 128 1, Rgba 128 0 255 1, Rgba 64 0 0 1
  , Rgba 128 64 0 1, Rgba 0 64 0 1, Rgba 0 64 64 1
  , Rgba 0 0 128 1, Rgba 0 0 64 1, Rgba 64 0 64 1
  , Rgba 64 0 128 1, Rgba 0 0 0 1, Rgba 128 128 0 1
  , Rgba 128 128 64 1, Rgba 128 128 128 1, Rgba 64 128 128 1
  , Rgba 192 192 192 1, Rgba 64 0 64 1, Rgba 255 255 255 1
  , Rgba 0 0 0 1
  ]

findReference :: BS.ByteString -> Maybe (String, Maybe Int)
findReference search = firstJust [tryAt j | j <- [0 .. BS.length search - 1]]
  where
    tryAt j = do
      guard (byteAt search j == Just 0x18)
      refLen <- word16LE search (j + 1)
      guard (refLen >= 1 && refLen <= 10)
      ref <- asciiAt search (j + 3) (fromIntegral refLen)
      guard (isRefDesignator ref)
      let viOff = j + 3 + fromIntegral refLen + 1
      pure (ref, fromIntegral <$> word16LE search viOff)

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

forwardOrcadPoint
  :: (Double, Double) -> Int -> (Double, Double) -> (Double, Double)
forwardOrcadPoint (x, y) orient (centerX, centerY) =
  let relativeX = x - centerX
      relativeY = y - centerY
      mirroredX = if orient .&. 0x04 /= 0 then negate relativeX else relativeX
      rotated = case orient .&. 0x03 of
        1 -> (relativeY, negate mirroredX)
        2 -> (negate mirroredX, negate relativeY)
        3 -> (negate relativeY, mirroredX)
        _ -> (mirroredX, relativeY)
  in (fst rotated + centerX, snd rotated + centerY)

detectMultiUnitComponents :: [Page] -> MultiUnitRegistry
detectMultiUnitComponents pages =
  MultiUnitRegistry
    { multiUnitGroups = groups
    , multiUnitCells = Map.fromList
        [ (cellName, (baseName, unitNumber))
        | (baseName, units) <- Map.toList groups
        , (cellName, unitNumber) <- units
        ]
    }
  where
    refCells = foldl addComponent Map.empty
      [ comp | page <- pages, comp <- pageComponents page ]

    addComponent refs comp
      | null (compRef comp) || null (compCell comp) = refs
      | otherwise =
          Map.insertWith
            (\new old -> old ++ new)
            (compRef comp)
            [compCell comp]
            refs

    candidates =
      [ (baseName, assignUnitNumbers baseName distinctCells)
      | (refName, cells) <- Map.toList refCells
      , let distinctCells = unique cells
      , length distinctCells > 1
      , let prefix = trimTrailingUnderscores (commonStringPrefix distinctCells)
            baseName = if null prefix then refName else prefix
      ]

    groups = foldl insertGroup Map.empty candidates
    insertGroup current (baseName, units) =
      Map.insertWith (\_ existing -> existing) baseName units current

assignUnitNumbers :: String -> [String] -> [(String, Int)]
assignUnitNumbers baseName = reverse . snd . foldl assign (Map.empty, [])
  where
    assign (used, assigned) cellName =
      let suffix = dropWhile (== '_') (drop (length baseName) cellName)
          proposed = case reverse suffix of
            lastChar : _ | isAlpha lastChar -> ord (toUpper lastChar) - ord 'A' + 1
            _ -> length assigned + 1
          unitNumber = firstUnused proposed used
      in ( Map.insert unitNumber () used
         , (cellName, unitNumber) : assigned
         )

    firstUnused candidate used
      | Map.member candidate used = firstUnused (candidate + 1) used
      | otherwise = candidate

componentUnitInfo :: MultiUnitRegistry -> String -> (String, Int)
componentUnitInfo registry cellName =
  Map.findWithDefault (cellName, 1) cellName (multiUnitCells registry)

componentLibName :: RenderConfig -> MultiUnitRegistry -> String -> String
componentLibName cfg registry cellName
  | useKicadRc cfg && cellName `elem` ["R", "C"] = "Device:" ++ cellName
  | otherwise = fst (componentUnitInfo registry cellName)

parseCacheSymbols :: BS.ByteString -> Map.Map String CacheSymbol
parseCacheSymbols body = Map.mapWithKey attachPinNumbers parsedSymbols
  where
    matches = findCellMatches body
    indexedMatches = zip [(0 :: Int)..] matches
    parsedSymbols = snd $ foldl parseRegion (Map.empty, Map.empty) indexedMatches
    numberLists = parseCachePinNumbers (Map.keys parsedSymbols) body

    attachPinNumbers cellName symbol =
      let numbers = Map.findWithDefault [] cellName numberLists
          numberedPins = zipWith (assignPinNumber numbers) [1..] (cachePins symbol)
      in symbol { cachePins = numberedPins }

    assignPinNumber numbers pinIndex pin =
      let number = case drop (pinIndex - 1) numbers of
            value : _ -> value
            [] -> show pinIndex
      in pin { pinNumber = number }

    parseRegion (seen, symbols) (idx, (_, cellEnd, cellName))
      | cellName `elem` ["TitleBlock", "Border"] =
          (Map.insert cellName () seen, symbols)
      | otherwise =
          let scanEnd = case drop (idx + 1) matches of
                (nextStart, _, _) : _ -> nextStart
                [] -> BS.length body
              pins = parsePins cellEnd scanEnd
              graphics =
                if Map.member cellName seen
                  then parseDuplicateGraphics cellEnd scanEnd
                  else emptyCacheSymbol
              visibility = parseCacheVisibility cellEnd scanEnd
              symbol = graphics
                { cachePins = pins
                , cachePinNamesVisible = fst <$> visibility
                , cachePinNumbersVisible = snd <$> visibility
                }
              symbols' =
                if cacheSymbolIsEmpty symbol
                  then symbols
                  else Map.insertWith mergeCacheSymbol cellName symbol symbols
          in (Map.insert cellName () seen, symbols')

    mergeCacheSymbol new old = CacheSymbol
      { cachePins =
          if length (cachePins new) > length (cachePins old)
            then cachePins new
            else cachePins old
      , cachePinNamesVisible =
          cachePinNamesVisible new `orElse` cachePinNamesVisible old
      , cachePinNumbersVisible =
          cachePinNumbersVisible new `orElse` cachePinNumbersVisible old
      , cacheRects = cacheRects old ++ cacheRects new
      , cacheLines = cacheLines old ++ cacheLines new
      , cacheEllipses = cacheEllipses old ++ cacheEllipses new
      , cacheArcs = cacheArcs old ++ cacheArcs new
      , cachePolygons = cachePolygons old ++ cachePolygons new
      , cachePolylines = cachePolylines old ++ cachePolylines new
      , cacheTexts = cacheTexts old ++ cacheTexts new
      }

    parseCacheVisibility start scanEnd =
      case reverse $ mapMaybe parseProperties candidateStarts of
        visibility : _ -> Just visibility
        [] -> Nothing
      where
        markerOffsets = filter (< scanEnd) (findAllFrom recordMarker start body)
        markerStarts = mapMaybe propertiesAfterPreamble markerOffsets
        directStarts = [max start (scanEnd - 1024) .. scanEnd - 1]
        candidateStarts = unique (markerStarts ++ directStarts)

        propertiesAfterPreamble markerAt = do
          payloadLengthWord <- word32LE body (markerAt + 4)
          payloadLength <- maybeWord32ToInt payloadLengthWord
          guard (payloadLength >= 0 && payloadLength <= 8000)
          pure (markerAt + 8 + payloadLength)

        parseProperties propertiesStart = do
          (_, afterPath) <- readVisibilityString propertiesStart
          (_, afterImplementation) <- readVisibilityString afterPath
          (refDes, afterRefDes) <- readVisibilityString afterImplementation
          (_, afterValue) <- readVisibilityString afterRefDes
          properties <- byteAt body afterValue
          trailing <- byteAt body (afterValue + 1)
          guard (afterValue + 2 <= scanEnd)
          guard (scanEnd - (afterValue + 2) <= 16)
          guard (not (null refDes) && length refDes <= 8 && all isAlphaNum refDes)
          guard (properties <= 0x3f && trailing == 0)
          pure (properties .&. 0x01 /= 0, properties .&. 0x04 == 0)

        readVisibilityString pos = do
          lengthWord <- word16LE body pos
          let stringLength = fromIntegral lengthWord
              stringStart = pos + 2
              stringEnd = stringStart + stringLength
          guard (stringLength >= 0 && stringLength <= 1024 && stringEnd <= scanEnd)
          value <- asciiAt body stringStart stringLength
          let nextPos = if byteAt body stringEnd == Just 0
                then stringEnd + 1
                else stringEnd
          pure (value, nextPos)

    parseDuplicateGraphics cellEnd scanEnd =
      case word16LE body cellEnd of
        Just pathLen ->
          let aps = cellEnd + 2 + fromIntegral pathLen + 1
          in if aps < scanEnd
             then parseCacheGraphics body aps scanEnd
             else emptyCacheSymbol
        Nothing -> emptyCacheSymbol

    parsePins pos scanEnd =
      zipWith setDefaultNumber [(1 :: Int)..] $
        modernPins ++ legacyPins
      where
        modernPins =
          mapMaybe parsePin $
            filter (< scanEnd) $
              takeWhile (< scanEnd) $
                findAllFrom recordMarker pos body
        legacyPins =
          mapMaybe (parseLegacyPin scanEnd) longPinRecords
          ++ mapMaybe (parseCompactLegacyPin scanEnd) compactPinRecords
        longPinRecords = filter (< scanEnd) $
          findAllFrom legacyPinPrefix pos body
        compactPinRecords = filter (< scanEnd) $
          findAllFrom compactLegacyPinPrefix pos body

    setDefaultNumber pinIndex pin = pin { pinNumber = show pinIndex }

    -- Shared tail of every cache pin encoding: a NUL-terminated,
    -- length-prefixed name at `nameLenPos`, then body and hot coordinates and a
    -- flags byte.  Only the preamble ahead of the name length tells the record
    -- marker form apart from the two Capture 7.x forms.  `limit` is the end of
    -- the cell's region where the caller scans a byte pattern rather than a
    -- self-delimiting record.
    pinFromNameAt nameLenPos limit = do
      nameLenWord <- word16LE body nameLenPos
      let nameLen = fromIntegral nameLenWord
          namePos = nameLenPos + 2
          nameEnd = namePos + nameLen
          coordOff = nameEnd + 1
      guard (nameLen >= 1 && nameLen <= 200)
      guard (maybe True (\scanEnd -> coordOff + 18 <= scanEnd) limit)
      name <- asciiAt body namePos nameLen
      guard (byteAt body nameEnd == Just 0)
      bx <- int32LE body coordOff
      by <- int32LE body (coordOff + 4)
      hx <- int32LE body (coordOff + 8)
      hy <- int32LE body (coordOff + 12)
      flags <- byteAt body (coordOff + 16)
      guard (all (\v -> abs v < 5000) [bx, by, hx, hy])
      pure Pin
        { pinName = name
        , pinNumber = ""
        , pinHotX = hx
        , pinHotY = hy
        , pinBodyX = bx
        , pinBodyY = by
        , pinFlags = fromIntegral flags
        }

    parsePin idx = do
      zeros <- word32LE body (idx + 4)
      guard (zeros == 0)
      pinFromNameAt (idx + 8) Nothing

    -- Capture 7.x caches use ordinary structure prefixes instead of the
    -- record marker introduced by later releases.  The scalar/bus tag is
    -- followed by the same length-prefixed name and four pin coordinates.
    legacyPinPrefix = BS.pack [0x1a, 0x01, 0x00, 0x18, 0x00]
    compactLegacyPinPrefix = BS.pack [0x1a, 0x00, 0x00]

    parseLegacyPin scanEnd idx = do
      pinKind <- word16LE body (idx + 5)
      guard (pinKind `elem` [0x19, 0x1a, 0x26])
      pinFromNameAt (idx + 7) (Just scanEnd)

    parseCompactLegacyPin scanEnd idx = pinFromNameAt (idx + 3) (Just scanEnd)

parseCachePinNumbers :: [String] -> BS.ByteString -> Map.Map String [String]
parseCachePinNumbers cellNames body =
  Map.fromList
    [ (cellName, best)
    | cellName <- cellNames
    , let token = BSC.pack (cellName ++ "\0")
          candidates = mapMaybe (parseListAt . (+ BS.length token)) (findAll token body)
          best = foldl chooseLonger [] candidates
    , not (null best)
    ]
  where
    parseListAt countPos = do
      countWord <- word16LE body countPos
      let count = fromIntegral countWord :: Int
      guard (count >= 2 && count <= 500)
      fst <$> parseEntries (countPos + 2) count

    parseEntries pos 0 = Just ([], pos)
    parseEntries pos remaining = do
      numberLenWord <- word16LE body pos
      let numberLen = fromIntegral numberLenWord
          separatorPos = pos + 2 + numberLen
      guard (numberLen >= 1 && numberLen <= 10)
      number <- asciiAt body (pos + 2) numberLen
      separator <- byteAt body separatorPos
      guard (separator == 0 || separator == 0x7f)
      let nextPos = skipSeparators separatorPos
      (rest, endPos) <- parseEntries nextPos (remaining - 1)
      pure (number : rest, endPos)

    skipSeparators pos =
      case byteAt body pos of
        Just value | value == 0 || value == 0x7f -> skipSeparators (pos + 1)
        _ -> pos

    chooseLonger current candidate
      | length candidate >= length current = candidate
      | otherwise = current

cacheSymbolIsEmpty :: CacheSymbol -> Bool
cacheSymbolIsEmpty symbol =
  null (cachePins symbol)
  && null (cacheRects symbol)
  && null (cacheLines symbol)
  && null (cacheEllipses symbol)
  && null (cacheArcs symbol)
  && null (cachePolygons symbol)
  && null (cachePolylines symbol)
  && null (cacheTexts symbol)

parseCacheGraphics :: BS.ByteString -> Int -> Int -> CacheSymbol
parseCacheGraphics body start scanEnd = go start emptyCacheSymbol
  where
    go pos acc
      | pos >= scanEnd - 10 = finish acc
      | otherwise =
          case word16LE body pos of
            Just 0x0030 -> parseEmbeddedGraphic pos acc
            Just 0x2828 -> parseRectRecord pos 10 26 acc
            Just 0x2929 -> parseLineRecord pos 10 26 acc
            Just 0x2b2b -> parseEllipseRecord pos 10 26 acc
            Just 0x2a2a -> parseArcRecord pos 10 42 acc
            Just 0x2c2c -> parsePolygonRecord pos acc
            Just 0x2d2d -> parsePolylineRecord pos acc
            Just 0x2e2e -> parseTextRecord pos acc
            _ -> jumpToNext pos 4 acc

    finish acc = acc
      { cacheRects = reverse (cacheRects acc)
      , cacheLines = reverse (cacheLines acc)
      , cacheEllipses = reverse (cacheEllipses acc)
      , cacheArcs = reverse (cacheArcs acc)
      , cachePolygons = reverse (cachePolygons acc)
      , cachePolylines = reverse (cachePolylines acc)
      , cacheTexts = reverse (cacheTexts acc)
      }

    parseEmbeddedGraphic pos acc =
      case (word16LE body (pos + 6), word16LE body (pos + 4)) of
        (Just 0x2828, _) -> parseRectRecord pos 16 32 acc
        (Just 0x2929, _) -> parseLineRecord pos 16 32 acc
        (Just 0x2b2b, _) -> parseEllipseRecord pos 16 32 acc
        (Just 0x2a2a, _) -> parseArcRecord pos 16 32 acc
        (Just 0x2c2c, _) -> parsePolygonRecord (pos + 6) acc
        (Just 0x2d2d, _) -> parsePolylineRecord (pos + 6) acc
        (Just 0x2e2e, _) -> parseTextRecord (pos + 6) acc
        (Just firstPair, Just count)
          | lowByte firstPair /= highByte firstPair
          , count >= 1 && count <= 500 ->
              parseLegacyPrimitives (pos + 6) (fromIntegral count) acc
        _ -> jumpToNext pos 32 acc

    lowByte value = value .&. 0xff
    highByte value = value `div` 0x100

    parseLegacyPrimitives :: Int -> Int -> CacheSymbol -> CacheSymbol
    parseLegacyPrimitives pos remaining acc
      | remaining == 0 = go pos acc
      | pos >= scanEnd = finish acc
      | otherwise =
          case byteAt body pos of
            Just 0x28 -> legacyQuad 0x28 pos remaining acc
            Just 0x29 -> legacyQuad 0x29 pos remaining acc
            Just 0x2b -> legacyQuad 0x2b pos remaining acc
            Just 0x2a -> legacyArc pos remaining acc
            _ -> finish acc

    legacyQuad :: Word8 -> Int -> Int -> CacheSymbol -> CacheSymbol
    legacyQuad tag pos remaining acc =
      case readI32Quad body (pos + 1) of
        Just (x1, y1, x2, y2)
          | validGraphicCoords [x1, y1, x2, y2] ->
              let acc' = case tag of
                    0x28 -> acc { cacheRects = Rect x1 y1 x2 y2 : cacheRects acc }
                    0x29 -> acc { cacheLines = Segment x1 y1 x2 y2 : cacheLines acc }
                    _ -> acc { cacheEllipses = Ellipse x1 y1 x2 y2 : cacheEllipses acc }
              in parseLegacyPrimitives (pos + 23) (remaining - 1) acc'
        _ -> finish acc

    legacyArc :: Int -> Int -> CacheSymbol -> CacheSymbol
    legacyArc pos remaining acc =
      case readI32Oct body (pos + 1) of
        Just (x1, y1, x2, y2, sx, sy, ex, ey)
          | validGraphicCoords [x1, y1, x2, y2, sx, sy, ex, ey] ->
              let acc' = acc
                    { cacheArcs = ArcShape x1 y1 x2 y2 sx sy ex ey : cacheArcs acc }
              in parseLegacyPrimitives (pos + 39) (remaining - 1) acc'
        _ -> finish acc

    parseRectRecord pos coordOff jumpOff acc =
      let acc' =
            case ( byteAt body (pos + 2)
                 , readI32Quad body (pos + coordOff)
                 ) of
              (Just 0x28, Just (x1, y1, x2, y2))
                | coordOff == 10 && validGraphicCoords [x1, y1, x2, y2] ->
                    acc { cacheRects = Rect x1 y1 x2 y2 : cacheRects acc }
              (_, Just (x1, y1, x2, y2))
                | coordOff /= 10 && validGraphicCoords [x1, y1, x2, y2] ->
                    acc { cacheRects = Rect x1 y1 x2 y2 : cacheRects acc }
              _ -> acc
      in jumpToNext pos jumpOff acc'

    parseLineRecord pos coordOff jumpOff acc =
      let acc' =
            case readI32Quad body (pos + coordOff) of
              Just (x1, y1, x2, y2)
                | validGraphicCoords [x1, y1, x2, y2]
                  && not (x1 == x2 && x2 == 0 && y1 == y2 && y2 == 0) ->
                    acc { cacheLines = Segment x1 y1 x2 y2 : cacheLines acc }
              _ -> acc
      in jumpToNext pos jumpOff acc'

    parseEllipseRecord pos coordOff jumpOff acc =
      let acc' =
            case readI32Quad body (pos + coordOff) of
              Just (x1, y1, x2, y2)
                | validGraphicCoords [x1, y1, x2, y2]
                  && not (x1 == x2 && x2 == 0 && y1 == y2 && y2 == 0) ->
                    acc { cacheEllipses = Ellipse x1 y1 x2 y2 : cacheEllipses acc }
              _ -> acc
      in jumpToNext pos jumpOff acc'

    parseArcRecord pos coordOff jumpOff acc =
      let acc' =
            case readI32Oct body (pos + coordOff) of
              Just (x1, y1, x2, y2, sx, sy, ex, ey)
                | validGraphicCoords [x1, y1, x2, y2, sx, sy, ex, ey] ->
                    acc { cacheArcs = ArcShape x1 y1 x2 y2 sx sy ex ey : cacheArcs acc }
              _ -> acc
      in jumpToNext pos jumpOff acc'

    parsePolygonRecord pos acc =
      case parsePolygonAt pos of
        Just (skip, polygon, extraSegments) ->
          let acc' = acc
                { cachePolygons = polygon ++ cachePolygons acc
                , cacheLines = extraSegments ++ cacheLines acc
                }
          in jumpToNext pos skip acc'
        Nothing -> jumpToNext pos 28 acc

    parsePolygonAt pos = do
      nvWord <- word16LE body (pos + 26)
      let nv = fromIntegral nvWord
          recLen = 28 + nv * 4
      guard (nv >= 3 && nv <= 50 && pos + recLen <= BS.length body)
      points <- mapM (\vi -> readStoredPolygonPoint (pos + 28 + vi * 4)) [0 .. nv - 1]
      guard (validPointCoords points)
      let (filled, extraSegments) = normalizeCachePolygon points
          polygons = if length filled >= 3 then [Polygon filled] else []
      pure (recLen, polygons, extraSegments)

    parsePolylineRecord pos acc =
      case parsePolylineAt pos of
        Just (skip, polyline) ->
          let acc' = acc { cachePolylines = polyline : cachePolylines acc }
          in jumpToNext pos skip acc'
        Nothing -> jumpToNext pos 12 acc

    parsePolylineAt pos = do
      byteLengthWord <- word32LE body (pos + 2)
      byteLength <- maybeWord32ToInt byteLengthWord
      let remaining = byteLength - 8
          totalLen = 2 + byteLength
      guard (byteLength >= 0 && pos + totalLen <= BS.length body)
      (nv, pointOff) <-
        if remaining >= 10 && (remaining - 10) `mod` 4 == 0
          then do
            n <- fromIntegral <$> word16LE body (pos + 18)
            pure (n, pos + 20)
          else if remaining >= 2 && (remaining - 2) `mod` 4 == 0
            then do
              n <- fromIntegral <$> word16LE body (pos + 10)
              pure (n, pos + 12)
            else Nothing
      guard (nv >= 2 && nv <= 50 && pointOff + nv * 4 <= BS.length body)
      points <- mapM (\vi -> readStoredPolylinePoint (pointOff + vi * 4)) [0 .. nv - 1]
      let deduped = dedupeConsecutive points
      guard (length deduped >= 2 && validPointCoords deduped)
      pure (totalLen, Polyline deduped)

    parseTextRecord pos acc =
      let acc' =
            case parseTextAt pos of
              Just ann -> acc { cacheTexts = ann : cacheTexts acc }
              Nothing -> acc
      in jumpToNext pos 26 acc'

    parseTextAt pos = do
      (x1, y1, x2, y2) <- readI32Quad body (pos + 10)
      ax <- int32LE body (pos + 26)
      ay <- int32LE body (pos + 30)
      textLenWord <- word16LE body (pos + 38)
      let textLen = fromIntegral textLenWord
      guard (textLen >= 1 && textLen <= 100)
      text <- asciiAt body (pos + 40) textLen
      guard (validGraphicCoords [x1, y1, x2, y2, ax, ay])
      pure (TextAnnotation x1 y1 x2 y2 ax ay text)

    readStoredPolygonPoint off = do
      y <- int16LE body off
      x <- int16LE body (off + 2)
      pure (x, y)

    readStoredPolylinePoint off = do
      y <- int16LE body off
      x <- int16LE body (off + 2)
      pure (x, y)

    jumpToNext pos skip acc =
      case findSubBefore recordMarker (pos + skip) scanEnd body of
        Just next -> go (next + 8) acc
        Nothing -> finish acc

    validGraphicCoords = all (\v -> abs v < 5000)
    validPointCoords = all (\(x, y) -> validGraphicCoords [x, y])

normalizeCachePolygon :: [(Int, Int)] -> ([(Int, Int)], [Segment])
normalizeCachePolygon vertices =
  case closedPoints of
    first : rest ->
      case elemIndex first rest of
        Just idx
          | length closedPoints >= 4 ->
              let closeIdx = idx + 1
                  filled = take closeIdx closedPoints
                  trailing = drop (closeIdx + 1) closedPoints
              in (filled, trailingSegments first trailing)
        _ -> (closedPoints, [])
    [] -> ([], [])
  where
    deduped = dedupeConsecutive vertices
    closedPoints =
      case deduped of
        [] -> []
        first : _
          | length deduped >= 2 && last deduped == first -> init deduped
          | otherwise -> deduped

    trailingSegments _ [] = []
    trailingSegments start (point:rest) = go start (point:rest)

    go _ [] = []
    go lastPoint (point:rest) =
      Segment (fst lastPoint) (snd lastPoint) (fst point) (snd point)
      : go point rest

isRefDesignator :: String -> Bool
isRefDesignator ref =
  let (letters, rest) = span isAlpha ref
      (digits, suffix) = span isDigit rest
  in not (null letters)
     && length letters <= 8
     && not (null digits)
     && length suffix <= 1
     && all isAlpha suffix

data KExpr
  = KAtom String
  | KString String
  | KList [KExpr]
  deriving Show

kAtom :: String -> KExpr
kAtom = KAtom

kString :: String -> KExpr
kString = KString

kNode :: String -> [KExpr] -> KExpr
kNode name children = KList (KAtom name : children)

kInt :: Int -> KExpr
kInt = KAtom . show

kDouble :: Double -> KExpr
kDouble = KAtom . fmt

kRawNum :: String -> KExpr
kRawNum = KAtom

renderKicad :: KExpr -> String
renderKicad expr = unlines (renderKExpr "" expr)

renderKExpr :: String -> KExpr -> [String]
renderKExpr indent expr =
  case expr of
    KAtom value -> [indent ++ value]
    KString _ -> [indent ++ renderScalar expr]
    KList [] -> [indent ++ "()"]
    KList children
      | all isScalar children ->
          [indent ++ "(" ++ unwords (map renderScalar children) ++ ")"]
      | otherwise ->
          let (prefix, rest) = span isScalar children
              opener = indent ++ "(" ++ unwords (map renderScalar prefix)
          in opener
             : concatMap (renderKExpr (indent ++ "\t")) rest
             ++ [indent ++ ")"]

isScalar :: KExpr -> Bool
isScalar KAtom{} = True
isScalar KString{} = True
isScalar KList{} = False

renderScalar :: KExpr -> String
renderScalar (KAtom value) = value
renderScalar (KString value) = "\"" ++ esc value ++ "\""
renderScalar (KList _) = error "nested S-expression cannot render as scalar"

kNo :: String -> KExpr
kNo name = kNode name [kAtom "no"]

kYes :: String -> KExpr
kYes name = kNode name [kAtom "yes"]

kAt :: [KExpr] -> KExpr
kAt = kNode "at"

kUuid :: String -> KExpr
kUuid value = kNode "uuid" [kString value]

kCoord :: Int -> KExpr
kCoord value = kDouble (fromIntegral value * unitToMm)

kXy :: Double -> Double -> KExpr
kXy x y = kNode "xy" [kDouble x, kDouble y]

kStroke :: String -> String -> KExpr
kStroke width strokeType =
  kNode "stroke"
    [ kNode "width" [kRawNum width]
    , kNode "type" [kAtom strokeType]
    ]

kFillType :: String -> KExpr
kFillType fillType =
  kNode "fill" [kNode "type" [kAtom fillType]]

kPolylineShape :: String -> String -> [(Double, Double)] -> KExpr
kPolylineShape strokeWidth fillType points =
  kNode "polyline"
    [ kNode "pts" [kXy x y | (x, y) <- points]
    , kStroke strokeWidth "default"
    , kFillType fillType
    ]

kCircleShape :: Double -> Double -> Double -> KExpr
kCircleShape cx cy radius =
  kNode "circle"
    [ kNode "center" [kDouble cx, kDouble cy]
    , kNode "radius" [kDouble radius]
    , kStroke "0.254" "default"
    , kFillType "none"
    ]

kArcShape :: Double -> Double -> Double -> Double -> Double -> Double -> KExpr
kArcShape sx sy mx my ex ey =
  kNode "arc"
    [ kNode "start" [kDouble sx, kDouble sy]
    , kNode "mid" [kDouble mx, kDouble my]
    , kNode "end" [kDouble ex, kDouble ey]
    , kStroke "0.254" "default"
    , kFillType "none"
    ]

kTextEffects :: KExpr
kTextEffects =
  kNode "effects"
    [ kNode "font"
        [ kNode "size" [kRawNum "1.27", kRawNum "1.27"]
        ]
    ]

kColor :: Rgba -> KExpr
kColor (Rgba red green blue alpha) =
  kNode "color" [kInt red, kInt green, kInt blue, kInt alpha]

kStyledTextEffects
  :: Double -> String -> Bool -> Bool -> Maybe Rgba -> [String] -> KExpr
kStyledTextEffects size face bold italic color justify =
  kNode "effects" $
    [ kNode "font" $
        [kNode "size" [kDouble size, kDouble size]]
        ++ [kNode "face" [kString face] | not (null face)]
        ++ [kYes "bold" | bold]
        ++ [kYes "italic" | italic]
        ++ maybe [] (\rgba -> [kColor rgba]) color
    ]
    ++ [kNode "justify" (map kAtom justify) | not (null justify)]

kStyledProperty
  :: String -> String -> KExpr -> Double -> String -> Bool -> Bool -> KExpr
kStyledProperty name value atExpr size face bold italic =
  kNode "property"
    [ kString name
    , kString value
    , atExpr
    , kStyledTextEffects size face bold italic Nothing []
    ]

kColoredStroke :: Double -> String -> Rgba -> KExpr
kColoredStroke width strokeType color =
  kNode "stroke"
    [ kNode "width" [kDouble width]
    , kNode "type" [kAtom strokeType]
    , kColor color
    ]

kPageFill :: String -> Maybe Rgba -> KExpr
kPageFill fillType color =
  kNode "fill" $
    [kNode "type" [kAtom fillType]]
    ++ maybe [] (\rgba -> [kColor rgba]) color

kProperty :: String -> String -> KExpr -> KExpr
kProperty name value atExpr =
  kNode "property" [kString name, kString value, atExpr, kTextEffects]

kHiddenProperty :: String -> String -> KExpr -> KExpr
kHiddenProperty name value atExpr =
  kNode "property"
    [ kString name
    , kString value
    , atExpr
    , kNode "effects"
        [ kNode "font"
            [ kNode "size" [kRawNum "1.27", kRawNum "1.27"]
            ]
        , kYes "hide"
        ]
    ]

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
                Just field -> componentFieldAt cfg comp field value fieldSize
                  fieldFace fieldBold fieldItalic
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

symbolPinVisibility :: String -> CacheSymbol -> (Bool, Bool)
symbolPinVisibility name symbol = (hidePinNames, hidePinNumbers)
  where
    pins = cachePins symbol

    hidePinNumbers =
      case cachePinNumbersVisible symbol of
        Just visible -> not visible || isTwoPinCapacitor
        Nothing ->
          length pins == 1
          || isTwoPinCapacitor
          || (length pins == 2 && any pinRecordHidesNumber pins)

    hidePinNames =
      case cachePinNamesVisible symbol of
        Just visible -> not visible
        Nothing ->
          length pins == 1
          || isTwoPinCapacitor
          || (length pins == 2 && any pinRecordHidesNumber pins)
          || (not (null pins) && all (\pin -> pinName pin == pinNumber pin) pins)

    isTwoPinCapacitor = length pins == 2 && isCapacitorCellName name

symbolPinsForOutput :: String -> CacheSymbol -> [Pin]
symbolPinsForOutput name symbol = map extendPin pins
  where
    pins = cachePins symbol
    (_, hidePinNumbers) = symbolPinVisibility name symbol
    longestNumber = maximum (0 : map (length . pinNumber) pins)
    numberLength = if hidePinNumbers then 10 else (longestNumber + 1) * 5
    minimumLength = fromIntegral (max 10 numberLength) :: Double
    (originX, originY) = symbolOrigin symbol

    extendPin pin
      | currentLength >= minimumLength - 0.01 = pin
      | otherwise =
          let (inwardX, inwardY) = inwardDirection pin
          in pin
            { pinHotX = round (fromIntegral (pinBodyX pin) - inwardX * minimumLength)
            , pinHotY = round (fromIntegral (pinBodyY pin) - inwardY * minimumLength)
            }
      where
        dx = fromIntegral (pinBodyX pin - pinHotX pin)
        dy = fromIntegral (pinBodyY pin - pinHotY pin)
        currentLength = sqrt (dx * dx + dy * dy)

    inwardDirection pin
      | distance > 0.01 = (dx / distance, dy / distance)
      | abs centerDx >= abs centerDy =
          (if centerDx <= 0 then 1 else -1, 0)
      | otherwise = (0, if centerDy <= 0 then 1 else -1)
      where
        dx = fromIntegral (pinBodyX pin - pinHotX pin)
        dy = fromIntegral (pinBodyY pin - pinHotY pin)
        distance = sqrt (dx * dx + dy * dy)
        centerDx = fromIntegral (pinHotX pin) - originX
        centerDy = fromIntegral (pinHotY pin) - originY

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

-- OrCAD's backslash marks the following character as overlined.  KiCad
-- groups adjacent overlined characters inside ~{...} markup.  For active-low
-- words such as R\T\S\, extend the overline to the initial letter as well;
-- a partly overlined word is visually ambiguous in KiCad.
orcadOverlineToKicad :: String -> String
orcadOverlineToKicad value =
  case fullyOverlinedWord value of
    Just word -> "~{" ++ word ++ "}"
    Nothing -> translateOverline value

fullyOverlinedWord :: String -> Maybe String
fullyOverlinedWord (first:'\\':rest)
  | isAlpha first = (first :) <$> markedTail rest
fullyOverlinedWord _ = Nothing

markedTail :: String -> Maybe String
markedTail [] = Nothing
markedTail ('\\':_) = Nothing
markedTail (first:rest) = (first :) <$> markedRest rest
  where
    markedRest [] = Just []
    markedRest ['\\'] = Just []
    markedRest ('\\':next:remaining) = (next :) <$> markedRest remaining
    markedRest _ = Nothing

translateOverline :: String -> String
translateOverline [] = []
translateOverline ['\\'] = []
translateOverline ('\\':next:rest) =
  let (overlined, remaining) = collectOverlined [next] rest
  in "~{" ++ overlined ++ "}" ++ translateOverline remaining
  where
    collectOverlined chars ('\\':following:remaining) =
      collectOverlined (following : chars) remaining
    collectOverlined chars remaining = (reverse chars, remaining)
translateOverline (char:rest) = char : translateOverline rest

symbolOrigin :: CacheSymbol -> (Double, Double)
symbolOrigin symbol =
  case cachePins symbol of
    pins@(_:_) ->
      let xs = [pinHotX pin | pin <- pins]
          ys = [pinHotY pin | pin <- pins]
      in midpoint xs ys
    [] ->
      case graphicCoords of
        [] -> (0, 0)
        coords ->
          let xs = [x | (x, _) <- coords]
              ys = [y | (_, y) <- coords]
          in midpoint xs ys
  where
    graphicCoords =
      concatMap rectCoords (cacheRects symbol)
      ++ concatMap segmentCoords (cacheLines symbol)
      ++ concatMap ellipseCoords (cacheEllipses symbol)
      ++ concatMap arcCoords (cacheArcs symbol)
      ++ concatMap polygonCoords (cachePolygons symbol)
      ++ concatMap polylineCoords (cachePolylines symbol)
      ++ concatMap textCoords (cacheTexts symbol)

    rectCoords (Rect x1 y1 x2 y2) = [(x1, y1), (x2, y2)]
    segmentCoords (Segment x1 y1 x2 y2) = [(x1, y1), (x2, y2)]
    ellipseCoords (Ellipse x1 y1 x2 y2) = [(x1, y1), (x2, y2)]
    arcCoords (ArcShape x1 y1 x2 y2 sx sy ex ey) =
      [(x1, y1), (x2, y2), (sx, sy), (ex, ey)]
    polygonCoords (Polygon points) = points
    polylineCoords (Polyline points) = points
    textCoords (TextAnnotation x1 y1 x2 y2 ax ay _) =
      [(x1, y1), (x2, y2), (ax, ay)]

    midpoint xs ys = (gridMidpoint xs, gridMidpoint ys)

-- Midpoint of an extent, snapped to OrCAD's integer grid.  Every symbol-local
-- coordinate is measured as (coordinate - origin), so an origin landing on a
-- half unit -- which a plain (min + max) / 2 does whenever the extent spans an
-- odd number of units -- shifts the entire symbol, pins included, half a unit
-- (0.127 mm) away from the wires drawn on the page.  The placement anchor is a
-- whole unit, so it cannot absorb the half.  Snapping here keeps pins exactly on
-- the page grid; the body moves by at most half a unit, which is invisible.
gridMidpoint :: [Int] -> Double
gridMidpoint values = fromIntegral ((minimum values + maximum values) `div` 2)

directionFromVector :: Double -> Double -> Int
directionFromVector dx dy
  | abs dx >= abs dy = if dx >= 0 then 0 else 180
  | dy < 0 = 270
  | otherwise = 90

pinElectricalType :: Pin -> String
pinElectricalType pin
  | map toUpper (pinName pin) == "NC" = "no_connect"
  | otherwise = "passive"

pinRecordHidesNumber :: Pin -> Bool
pinRecordHidesNumber pin = pinFlags pin .&. 0x01 == 0

isCapacitorCellName :: String -> Bool
isCapacitorCellName cellName =
  let upperName = map toUpper cellName
  in upperName == "C"
     || "CAP" `isPrefixOf` upperName
     || "CP" `isPrefixOf` upperName

ellipsePoints :: Double -> Double -> Double -> Double -> Int -> [(Double, Double)]
ellipsePoints cx cy rx ry steps =
  [ let angle = 2 * pi * fromIntegral i / fromIntegral steps
    in (cx + rx * cos angle, cy + ry * sin angle)
  | i <- [0 .. steps]
  ]

arcMidpoint
  :: Double -> Double -> Double -> Double -> Double -> Double -> Double -> Double
  -> (Double, Double)
arcMidpoint cx cy rx ry sx sy ex ey =
  let aStart = atan2 (safeDiv (sy - cy) ry) (safeDiv (sx - cx) rx)
      rawEnd = atan2 (safeDiv (ey - cy) ry) (safeDiv (ex - cx) rx)
      aEnd = if rawEnd <= aStart then rawEnd + 2 * pi else rawEnd
      aMid = (aStart + aEnd) / 2
  in (cx + rx * cos aMid, cy + ry * sin aMid)

arcPoints
  :: Double -> Double -> Double -> Double -> Double -> Double -> Double -> Double -> Int
  -> [(Double, Double)]
arcPoints cx cy rx ry sx sy ex ey steps =
  [ let angle = aStart + (aEnd - aStart) * fromIntegral i / fromIntegral steps
    in (cx + rx * cos angle, cy + ry * sin angle)
  | i <- [0 .. steps]
  ]
  where
    aStart = atan2 (safeDiv (sy - cy) ry) (safeDiv (sx - cx) rx)
    rawEnd = atan2 (safeDiv (ey - cy) ry) (safeDiv (ex - cx) rx)
    aEnd = if rawEnd <= aStart then rawEnd + 2 * pi else rawEnd

safeDiv :: Double -> Double -> Double
safeDiv _ denom | abs denom < 0.000001 = 0
safeDiv numerator denom = numerator / denom

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

orientToAngle :: Int -> Int
orientToAngle orient = case orient .&. 0x03 of
  0 -> 0
  1 -> 90
  2 -> 180
  _ -> 270

componentAngle :: Component -> Int
componentAngle component =
  let angle = orientToAngle (compOrient component)
  in if compOrient component .&. 0x04 /= 0
       then (360 - angle) `mod` 360
       else angle

componentAngleFor :: RenderConfig -> Component -> Int
componentAngleFor cfg component
  | useKicadRc cfg && compCell component `elem` ["R", "C"] =
      (90 - orientToAngle (compOrient component)) `mod` 360
  | otherwise = componentAngle component

standardDevicePinPoint :: Component -> String -> Maybe (Int, Int)
standardDevicePinPoint component rawNumber = do
  localY <- Map.lookup effectiveNumber (Map.fromList [("1", 15), ("2", -15)])
  let angle = (90 - orientToAngle (compOrient component)) `mod` 360
      (rotatedX, rotatedY) = case angle of
        90 -> (-localY, 0)
        180 -> (0, -localY)
        270 -> (localY, 0)
        _ -> (0, localY)
  pure (compX component + rotatedX, compY component + rotatedY)
  where
    mirrored = compOrient component .&. 0x04 /= 0
    effectiveNumber
      | mirrored && rawNumber == "1" = "2"
      | mirrored && rawNumber == "2" = "1"
      | otherwise = rawNumber

-- KiCad's outline-font renderer applies m_outlineFontSizeCompensation = 1.4 when
-- scaling glyphs, so a (size 10 10) value renders at 14 mm em-height. Under
-- --kicad-fonts the stroke font is not inflated (1.0). Newstroke caps run ~1.12x
-- past the nominal box.
kicadFontSizeCompensation :: Double
kicadFontSizeCompensation = 1.4

newstrokeCapInflation :: Double
newstrokeCapInflation = 1.12

-- Caller face names normalise to the generated table keys (see text_metrics.py).
faceAliases :: Map.Map String String
faceAliases = Map.fromList
  [ ("", "arial")
  , ("kicad font", "newstroke")
  , ("kicad", "newstroke")
  , ("stroke", "newstroke")
  ]

-- Metrics entry for (face, bold, italic), falling back to Arial like the Python
-- text_metrics._resolve does.
resolveFaceMetrics :: String -> Bool -> Bool -> Maybe FaceMetrics
resolveFaceMetrics faceName bold italic =
  firstJust [Map.lookup key fontMetrics | key <- candidates]
  where
    lowered = map toLower (if null faceName then "arial" else faceName)
    name = Map.findWithDefault lowered lowered faceAliases
    candidates =
      [(name, bold, italic), ("arial", bold, italic), ("arial", False, False)]

-- Rendered width of a string in mm at the given KiCad size: sums per-glyph
-- advance widths (font units) and scales by size / units_per_em, mirroring
-- text_metrics.measure_text_width. Falls back to 0.6 * size * length with no
-- table available.
measureTextWidth :: String -> Double -> String -> Bool -> Bool -> Double
measureTextWidth s sizeMm faceName bold italic
  | null s = 0
  | otherwise = case resolveFaceMetrics faceName bold italic of
      Nothing -> 0.6 * sizeMm * fromIntegral (length s)
      Just fm ->
        let advance ch = maybe (fmDefaultAdvance fm)
              (\(a, _, _) -> a) (Map.lookup ch (fmGlyphs fm))
        in fromIntegral (sum (map advance s))
             / fromIntegral (fmUnitsPerEm fm) * sizeMm

-- Rendered glyph-bbox height (max ascent minus min descent, spaces ignored), so
-- an all-caps/digit string reports its cap height. Mirrors
-- text_metrics.measure_text_height.
measureTextHeight :: String -> Double -> String -> Bool -> Bool -> Double
measureTextHeight s sizeMm faceName bold italic
  | null s = 0
  | otherwise = case resolveFaceMetrics faceName bold italic of
      Nothing -> sizeMm
      Just fm ->
        let inked =
              [ (top, bot)
              | ch <- s
              , ch /= ' '
              , Just (_, top, bot) <- [Map.lookup ch (fmGlyphs fm)]
              ]
        in case inked of
             [] -> sizeMm
             _ ->
               let top = maximum (map fst inked)
                   bot = minimum (map snd inked)
               in fromIntegral (top - bot) / fromIntegral (fmUnitsPerEm fm) * sizeMm

-- Face used for measurement: KiCad's Newstroke stroke font under --kicad-fonts
-- (which emits no face token), else the OrCAD face (≈ Arial).
measureFaceName :: Bool -> String -> String
measureFaceName useKicadFonts face =
  if useKicadFonts then "newstroke" else (if null face then "Arial" else face)

-- Rendered (width, height) in mm of a Reference/Value field, used to turn its
-- OrCAD top-left anchor into a centre (mirrors _text_box_dims). Width is the
-- actual rendered text width. For the height, --kicad-fonts uses a consistent
-- cap reference ('0') instead of the per-string ink extent: KiCad's Newstroke
-- '/' (and descenders) span well past the cap box, so centring on that extent
-- would drop slash-bearing values (e.g. "22/0603") below cap-only designators
-- (e.g. "R2"). Default (outline) mode keeps the per-string extent — ~cap height
-- for Arial, and what the PDF placement tests validate.
textBoxDims :: Bool -> String -> Double -> String -> Bool -> Bool -> (Double, Double)
textBoxDims useKicadFonts text sizeMm face bold italic = (width, height)
  where
    mface = measureFaceName useKicadFonts face
    comp = if useKicadFonts then 1.0 else kicadFontSizeCompensation
    width = measureTextWidth text sizeMm mface bold italic * comp
    heightRef = if useKicadFonts then "0" else text
    height = measureTextHeight heightRef sizeMm mface bold italic * comp

-- OrCAD's display-prop (x, y) lands at the axis-aligned top-left of the rendered
-- text box; KiCad anchors text at its centre.  Convert between them, measuring
-- the box with real per-glyph metrics (a char-count estimate is off by ~0.8 mm
-- horizontally and ~0.9 mm vertically) and applying the perpendicular nudge from
-- the OrCAD em-box top to the cap-height top -- an empirical fraction of the
-- font size that aligns with OrCAD's PDF.  Both component Reference/Value fields
-- and power-symbol values are placed this way.
orcadTextTopLeftToCenter
  :: Bool -> String -> Double -> String -> Bool -> Bool -> Int
  -> (Double, Double) -> (Double, Double)
orcadTextTopLeftToCenter
  useKicadFonts text size face bold italic angle (topLeftX, topLeftY) =
    (topLeftX + boxWidth / 2 + nudgeX, topLeftY + boxHeight / 2 + nudgeY)
  where
    (textWidth, textHeight) = textBoxDims useKicadFonts text size face bold italic
    (boxWidth, boxHeight) = if angle `elem` [90, 270]
      then (textHeight, textWidth)
      else (textWidth, textHeight)
    nudge = 0.416 * size
    (nudgeX, nudgeY) = case angle of
      90 -> (nudge, 0)
      180 -> (0, -nudge)
      270 -> (-nudge, 0)
      _ -> (0, nudge)

componentFieldAt
  :: RenderConfig -> Component -> DisplayField -> String -> Double
  -> String -> Bool -> Bool -> KExpr
componentFieldAt cfg component field value size face bold italic =
  kAt [kDouble centerX, kDouble centerY, kInt relativeAngle]
  where
    absoluteAngle = displayTextAngle field `mod` 360
    relative = (absoluteAngle - componentAngleFor cfg component) `mod` 360
    relativeAngle = if relative >= 180 then relative - 180 else relative
    -- OrCAD stores ref/value offsets against the instance *loc*, never against
    -- the body origin. The two coincide for the 0/180 family, but the body
    -- origin is recovered by pin matching, so for a part with no usable pins
    -- (e.g. the SCR1 mounting screw) it is unreliable and drags the labels with
    -- it. Anchoring to loc unconditionally matches the Python converter.
    originX = fromIntegral (compLocX component)
    originY = fromIntegral (compLocY component)
    topLeftX = (originX + fromIntegral (displayOffsetX field)) * unitToMm
    topLeftY = (originY + fromIntegral (displayOffsetY field)) * unitToMm
    (centerX, centerY) =
      orcadTextTopLeftToCenter (useKicadFonts cfg) value size face bold italic
        absoluteAngle (topLeftX, topLeftY)

defaultComponentTextStyle :: Bool -> [TextStyle] -> (Double, String, Bool, Bool)
defaultComponentTextStyle useKicadFonts styles =
  case reverse (sortOn snd (Map.toList counts)) of
    [] -> (1.27, selectedFace "Arial", False, False)
    (((height, face), _):_) ->
      ( max 0.5 (fromIntegral height * unitToMm / 1.4)
      , selectedFace face
      , False
      , False
      )
  where
    selectedFace face = if useKicadFonts then "" else face
    candidates =
      [ (abs (textStyleTag style), textStyleFace style)
      | style <- styles
      , textStyleWeight style == 400
      , not (textStyleItalic style)
      , textStyleFace style `elem` ["", "Arial"]
      , textStyleTag style /= 0
      ]
    counts = Map.fromListWith (+) [(candidate, 1 :: Int) | candidate <- candidates]

textStyleForId :: [TextStyle] -> Int -> Maybe TextStyle
textStyleForId styles styleId
  | styleId >= 1 && styleId <= length styles = Just (styles !! (styleId - 1))
  | otherwise = Nothing

normalizedTextRotation :: Int -> Int
normalizedTextRotation escapement = (escapement `div` 10) `mod` 360

nonEmptyTextLines :: String -> [String]
nonEmptyTextLines value =
  case filter (not . all isSpace) (lines (normalizeNewlines value)) of
    [] -> [""]
    textLines -> textLines
  where
    normalizeNewlines [] = []
    normalizeNewlines ('\r':'\n':rest) = '\n' : normalizeNewlines rest
    normalizeNewlines ('\r':rest) = '\n' : normalizeNewlines rest
    normalizeNewlines (char:rest) = char : normalizeNewlines rest

pageTextSize :: Bool -> PageText -> Maybe TextStyle -> [String] -> Int -> Double
pageTextSize useKicadFonts pageText style textLines rotation =
  if physicalWidth <= 0 || physicalHeight <= 0
    then max 0.5 (min 32 styleFallback)
    else max 0.5 (min 32 (min heightLimited widthLimited))
  where
    physicalWidth = fromIntegral (abs (pageTextX2 pageText - pageTextX1 pageText))
      * unitToMm
    physicalHeight = fromIntegral (abs (pageTextY2 pageText - pageTextY1 pageText))
      * unitToMm
    rotated = rotation `elem` [90, 270]
    readingWidth = if rotated then physicalHeight else physicalWidth
    readingHeight = if rotated then physicalWidth else physicalHeight
    lineCount = max 1 (length textLines)
    -- Size the text so the longest line's rendered width matches the bbox width.
    -- The line is chosen by character count and only then measured with real
    -- per-glyph metrics, mirroring `max(lines, key=len)` in dsn2kicad_py.py --
    -- including its tie-break, which keeps the *first* longest line (maximumBy
    -- would have kept the last).
    face = maybe "" textStyleFace style
    bold = maybe False ((== 700) . textStyleWeight) style
    italic = maybe False textStyleItalic style
    mface = measureFaceName useKicadFonts face
    widestLine = case textLines of
      [] -> ""
      firstLine : rest -> foldl longerLine firstLine rest
    longerLine best candidate
      | length candidate > length best = candidate
      | otherwise = best
    widthAtOne = max 1.0e-3 (measureTextWidth widestLine 1.0 mface bold italic)
    -- Outline inflates both axes by 1.4; the Newstroke stroke font inflates
    -- advance widths ~1.0x but caps ~1.12x, so width and height differ.
    heightCompensation =
      if useKicadFonts then kicadFontSizeCompensation * newstrokeCapInflation
      else kicadFontSizeCompensation
    widthCompensation = if useKicadFonts then 1.0 else kicadFontSizeCompensation
    heightLimited = readingHeight / fromIntegral lineCount / heightCompensation
    widthLimited = readingWidth / widthAtOne / widthCompensation
    styleFallback = maybe 1.27
      (\textStyle -> fromIntegral (abs (textStyleTag textStyle)) * unitToMm / 1.4)
      style

pageTextLinePosition :: PageText -> Double -> Int -> Int -> Int -> (Double, Double)
pageTextLinePosition pageText size rotation lineIndex lineCount =
  case rotation of
    90 -> (x1 + step + descender, y1 + height)
    180 -> (x1 + width, y1 + height - step - descender)
    270 -> (x1 + width - step - descender, y1)
    _ -> (x1, y1 + step + descender)
  where
    x1 = fromIntegral (pageTextX1 pageText) * unitToMm
    y1 = fromIntegral (pageTextY1 pageText) * unitToMm
    width = fromIntegral (abs (pageTextX2 pageText - pageTextX1 pageText)) * unitToMm
    height = fromIntegral (abs (pageTextY2 pageText - pageTextY1 pageText)) * unitToMm
    rotated = rotation `elem` [90, 270]
    readingHeight = if rotated then width else height
    lineHeight = if lineCount > 0
      then readingHeight / fromIntegral lineCount
      else size * 1.2
    step = fromIntegral (lineIndex + 1) * lineHeight
    descender = 0.30 * size

powerSymbolAngle :: PowerSymbol -> Int
powerSymbolAngle symbol = ((powerOrient symbol `div` 256) .&. 0x03) * 90

powerValueAngle :: PowerSymbol -> Int
powerValueAngle symbol =
  let angle = fromMaybe (powerSymbolAngle symbol) (powerValueRotation symbol)
      relative = (angle - powerSymbolAngle symbol) `mod` 360
  in if relative >= 180 then relative - 180 else relative

-- Returns the KiCad centre anchor in **millimetres** for a power symbol's value
-- text, placed the same way component Reference/Value fields are.
powerValueCenter
  :: Bool -> Double -> String -> Bool -> Bool -> PowerSymbol
  -> Maybe (Double, Double)
powerValueCenter useKicadFonts size face bold italic symbol = do
  (offX, offY) <- powerValueOffset symbol
  let (_, _, y2, x2, x1, y1) = powerCoords symbol
      topLeftX = fromIntegral (min x1 x2 + offX) * unitToMm
      topLeftY = fromIntegral (min y1 y2 + offY) * unitToMm
      rotation = fromMaybe 0 (powerValueRotation symbol)
  pure $
    orcadTextTopLeftToCenter useKicadFonts (powerNetName symbol) size face bold
      italic rotation (topLeftX, topLeftY)

pageObjectUuid :: BS.ByteString -> Page -> Int -> Int -> String
pageObjectUuid seed page category objectIndex =
  deterministicUuid seed $
    pageStreamName page ++ ":" ++ show category ++ ":" ++ show objectIndex

pagePinUuid :: BS.ByteString -> Page -> Int -> Int -> String
pagePinUuid seed page componentIndex pinIndex =
  pageObjectUuid seed page 3 (componentIndex * 1000000 + pinIndex)

-- Emitted coordinate precision.  A symbol pin's page position is the sum of two
-- separately emitted numbers (the placement anchor and the symbol-local offset)
-- while the wire that lands on it is emitted as a single number, so quantising
-- each term to two decimals let the two roundings accumulate past half a step
-- and pushed pins 0.01 mm off their wires -- which KiCad reads as unconnected.
-- Four decimals represents every OrCAD grid coordinate (an integer multiple of
-- 0.254 mm needs at most three) exactly, so the sum is exact too.
fmtDecimals :: Int
fmtDecimals = 4

fmt :: Double -> String
fmt value =
  let normalized = if abs value < 0.5 / 10 ^ fmtDecimals then 0 else value
  in trimTrailingZeros (showFFloat (Just fmtDecimals) normalized "")

-- "255.0160" -> "255.016", "60.0000" -> "60".  KiCad accepts both forms; the
-- shorter one keeps the emitted files close to what KiCad itself writes.
trimTrailingZeros :: String -> String
trimTrailingZeros rendered
  | '.' `notElem` rendered = rendered
  | otherwise =
      case reverse (dropWhile (== '0') (reverse rendered)) of
        trimmed
          | "." `isSuffixOf` trimmed -> init trimmed
          | otherwise -> trimmed

esc :: String -> String
esc = concatMap escChar
  where
    escChar '"' = "\\\""
    escChar '\\' = "\\\\"
    escChar c
      | ord c < 32 = "?"
      | otherwise = [c]

escJson :: String -> String
escJson = esc
