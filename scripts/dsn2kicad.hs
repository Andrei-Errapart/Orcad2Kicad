#!/usr/bin/env runghc
{-# LANGUAGE ScopedTypeVariables #-}

-- Copyright (C) 2026 Andrei Errapart
-- SPDX-License-Identifier: GPL-2.0-or-later

import Control.Monad (forM_, guard, unless)
import Data.Array (Array, (!), array, listArray)
import qualified Data.Array.Unboxed as U
import Data.Bits
  ( (.&.)
  , (.|.)
  , complement
  , rotateR
  , shiftL
  , shiftR
  , xor
  )
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Char (isAlpha, isAlphaNum, isDigit, isSpace, ord, toLower, toUpper)
import Data.Int (Int16, Int32)
import Data.List
  ( elemIndex
  , intercalate
  , isInfixOf
  , isPrefixOf
  , isSuffixOf
  , sortOn
  )
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust, mapMaybe)
import qualified Data.Set as Set
import Data.Word (Word8, Word16, Word32, Word64)
import Numeric (showFFloat, showHex)
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

unitToMm :: Double
unitToMm = 0.254

recordMarker :: BS.ByteString
recordMarker = BS.pack [0xff, 0xe4, 0x5c, 0x39]

netTableAnchor :: BS.ByteString
netTableAnchor = BS.pack
  [0x30, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00]

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

-- | Encoding of the Library string pool.  OrCAD writes it in the authoring
-- machine's Windows ANSI codepage and records which one nowhere, so it is
-- either detected (see `detectSourceEncoding`) or named on the command line.
data SourceEncoding
  = EncUtf8
  | EncCp1252
  | EncCp932
  | EncCp936
  | EncCp950
  deriving (Eq, Show)

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

encodingFlagPrefix :: String
encodingFlagPrefix = "--source-encoding="

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

-- | Codepage names accepted by --source-encoding, with the usual aliases.
sourceEncodingAliases :: [(String, SourceEncoding)]
sourceEncodingAliases =
  [ ("utf-8", EncUtf8), ("utf8", EncUtf8)
  , ("cp1252", EncCp1252), ("windows-1252", EncCp1252), ("ansi", EncCp1252)
  , ("cp932", EncCp932), ("shift-jis", EncCp932), ("shift_jis", EncCp932)
  , ("sjis", EncCp932)
  , ("cp936", EncCp936), ("gbk", EncCp936), ("gb2312", EncCp936)
  , ("cp950", EncCp950), ("big5", EncCp950)
  ]

sourceEncodingNames :: [String]
sourceEncodingNames = map fst sourceEncodingAliases

sourceEncodingByName :: String -> Maybe SourceEncoding
sourceEncodingByName name = lookup (map toLower name) sourceEncodingAliases

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
      sourceEncoding = detectSourceEncoding (optSourceEncoding opts) libraryBody
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
      pageFiles =
        [ (pageOutputName page, generatePageSch
            dsnDigest opts project cacheSymbols multiUnits powerRefs
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
       , (project ++ ".kicad_sym", generateSymbolLibrary opts cacheSymbols multiUnits pages)
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

splitSlash :: String -> [String]
splitSlash = splitOn '/'

splitOn :: Char -> String -> [String]
splitOn separator value =
  case break (== separator) value of
    (part, []) -> [part]
    (part, _:rest) -> part : splitOn separator rest

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

sliceAt :: BS.ByteString -> Int -> Int -> Maybe BS.ByteString
sliceAt bytes start size
  | start >= 0 && size >= 0 && start + size <= BS.length bytes =
      Just (BS.take size (BS.drop start bytes))
  | otherwise = Nothing

words32LE :: BS.ByteString -> [Word32]
words32LE bytes =
  [value | off <- [0, 4 .. BS.length bytes - 4], Just value <- [word32LE bytes off]]

word64ToInt :: String -> Word64 -> Either String Int
word64ToInt label value
  | value <= fromIntegral (maxBound :: Int) = Right (fromIntegral value)
  | otherwise = Left (label ++ " too large")

word32ToInt :: String -> Word32 -> Either String Int
word32ToInt label value =
  maybe (Left (label ++ " too large")) Right (maybeWord32ToInt value)

maybeWord32ToInt :: Word32 -> Maybe Int
maybeWord32ToInt value
  | fromIntegral value <= (maxBound :: Int) = Just (fromIntegral value)
  | otherwise = Nothing

sidToMaybe :: Word32 -> Maybe Int
sidToMaybe sid
  | sid == noStream = Nothing
  | otherwise = maybeWord32ToInt sid

isRegularSector :: Word32 -> Bool
isRegularSector sid = sid <= maxRegularSector

decodeUtf16LeName :: BS.ByteString -> String
decodeUtf16LeName bytes =
  [ codeUnitToChar value
  | off <- [0, 2 .. BS.length bytes - 2]
  , Just value <- [word16LE bytes off]
  , value /= 0
  ]
  where
    codeUnitToChar value
      | value >= 0xd800 && value <= 0xdfff = '?'
      | otherwise = toEnum (fromIntegral value)

showHex32 :: Word32 -> String
showHex32 value =
  let digits = "0123456789abcdef"
      nybble :: Int -> Char
      nybble shift = digits !! fromIntegral ((value `div` (16 ^ shift)) .&. 0xf)
  in "0x" ++ [nybble s | s <- [7,6..0 :: Int]]

need :: String -> Maybe a -> Either String a
need label = maybe (Left ("missing " ++ label)) Right

unlessEither :: Bool -> String -> Either String ()
unlessEither True _ = Right ()
unlessEither False err = Left err

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

stripStringPrefix :: String -> String -> Maybe String
stripStringPrefix [] value = Just value
stripStringPrefix _ [] = Nothing
stripStringPrefix (expected:prefix) (actual:value)
  | expected == actual = stripStringPrefix prefix value
  | otherwise = Nothing

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

textRecordType :: BS.ByteString
textRecordType = BS.pack [0x01, 0x00, 0x2e, 0x2e]

pageRectTag, pageLineTag, pageEllipseTag, pagePolygonTag :: BS.ByteString
pageRectTag = BS.pack [0x01, 0x00, 0x28, 0x28, 0x28, 0x00]
pageLineTag = BS.pack [0x01, 0x00, 0x29, 0x29, 0x20, 0x00]
pageEllipseTag = BS.pack [0x01, 0x00, 0x2b, 0x2b, 0x28, 0x00]
pagePolygonTag = BS.pack [0x01, 0x00, 0x2c, 0x2c, 0x2e, 0x00]

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

-- | Decode a legacy double-byte codepage.  `Nothing` on the first byte or pair
-- the table leaves unassigned, which is what makes the tables usable as
-- evidence in `detectSourceEncoding` -- a wrong guess usually fails outright.
decodeCodepage :: Codepage -> BS.ByteString -> Maybe String
decodeCodepage table = go . BS.unpack
  where
    trailSpan = cpTrailHi table - cpTrailLo table + 1

    go [] = Just []
    go (byte : rest)
      | byte < 0x80 = (toEnum (fromIntegral byte) :) <$> go rest
      | otherwise = case singleAt byte of
          Just ch -> (ch :) <$> go rest
          Nothing -> case rest of
            trail : more -> do
              ch <- doubleAt byte trail
              (ch :) <$> go more
            [] -> Nothing

    singleAt byte =
      case cpSingle table U.! (fromIntegral byte - 0x80) of
        '\0' -> Nothing
        ch -> Just ch

    -- The range guards must come first: they keep the index inside the array.
    doubleAt leadByte trailByte
      | lead < cpLeadLo table || lead > cpLeadHi table = Nothing
      | trail < cpTrailLo table || trail > cpTrailHi table = Nothing
      | ch == '\0' = Nothing
      | otherwise = Just ch
      where
        lead = fromIntegral leadByte
        trail = fromIntegral trailByte
        ch = cpDouble table
          U.! ((lead - cpLeadLo table) * trailSpan + (trail - cpTrailLo table))

-- | CP1252 is single-byte and total: the five unassigned slots become U+FFFD.
decodeCp1252 :: BS.ByteString -> String
decodeCp1252 = map decodeByte . BS.unpack
  where
    decodeByte byte
      | byte < 0x80 = toEnum (fromIntegral byte)
      | otherwise = case cp1252High U.! (fromIntegral byte - 0x80) of
          '\0' -> '\65533'
          ch -> ch

-- | Strict UTF-8: rejects overlong forms, surrogates and out-of-range code
-- points, so that "decodes cleanly" is real evidence rather than a formality.
decodeUtf8Strict :: BS.ByteString -> Maybe String
decodeUtf8Strict = go . BS.unpack
  where
    go [] = Just []
    go (b0 : rest)
      | b0 < 0x80 = emit (fromIntegral b0) rest
      | b0 < 0xc2 = Nothing
      | b0 < 0xe0 = case rest of
          b1 : more | cont b1 ->
            emit (((fromIntegral b0 - 0xc0) `shiftL` 6) + trailing b1) more
          _ -> Nothing
      | b0 < 0xf0 = case rest of
          b1 : b2 : more | cont b1 && cont b2 ->
            let code = ((fromIntegral b0 - 0xe0) `shiftL` 12)
                  + (trailing b1 `shiftL` 6) + trailing b2
            in if code < 0x800 || (code >= 0xd800 && code <= 0xdfff)
                 then Nothing
                 else emit code more
          _ -> Nothing
      | b0 < 0xf5 = case rest of
          b1 : b2 : b3 : more | cont b1 && cont b2 && cont b3 ->
            let code = ((fromIntegral b0 - 0xf0) `shiftL` 18)
                  + (trailing b1 `shiftL` 12) + (trailing b2 `shiftL` 6)
                  + trailing b3
            in if code < 0x10000 || code > 0x10ffff
                 then Nothing
                 else emit code more
          _ -> Nothing
      | otherwise = Nothing

    emit code rest = (toEnum code :) <$> go rest
    cont byte = byte >= 0x80 && byte < 0xc0
    trailing byte = fromIntegral byte - 0x80 :: Int

codepageTableFor :: SourceEncoding -> Maybe Codepage
codepageTableFor enc = case enc of
  EncCp932 -> Just cp932Table
  EncCp936 -> Just cp936Table
  EncCp950 -> Just cp950Table
  _ -> Nothing

-- | Decode one pooled string.  A string the chosen codepage cannot represent
-- falls back to CP1252 on its own, because real designs mix codepages in one
-- pool: board 0100 carries both a CP1252 0xB0 and a GBK 0xA1E3 degree sign.
-- Whole-file strictness would turn every such string into replacement
-- characters, which is worse than the mojibake it replaces.
decodeLibraryString :: SourceEncoding -> BS.ByteString -> String
decodeLibraryString enc raw
  | BS.all (< 0x80) raw = BSC.unpack raw
  | otherwise = case enc of
      EncUtf8 -> orCp1252 (decodeUtf8Strict raw)
      EncCp1252 -> decodeCp1252 raw
      _ -> orCp1252 (codepageTableFor enc >>= \table -> decodeCodepage table raw)
  where
    orCp1252 = fromMaybe (decodeCp1252 raw)

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

-- | Font names that identify a codepage's script.  Substrings, because OrCAD
-- records decorated variants ("@" for vertical, a trailing weight).
knownFaceNames :: SourceEncoding -> [String]
knownFaceNames enc = case enc of
  EncCp936 ->
    [ "\24494\36719\38597\40657"      -- Microsoft YaHei
    , "\23435\20307", "\40657\20307"  -- SimSun, SimHei
    , "\31561\32447", "\20223\23435"  -- DengXian, FangSong
    , "\26999\20307", "\38582\20070"  -- KaiTi, LiShu
    , "\24188\22278", "\21326\25991"  -- YouYuan, STXxx
    , "\26041\27491", "\24605\28304"  -- FangZheng, Source Han
    ]
  EncCp932 ->
    [ "\12468\12471\12483\12463"      -- Gothic
    , "\26126\26397"                  -- Mincho
    , "\12513\12452\12522\12458"      -- Meiryo
    , "\65325\65331"                  -- fullwidth "MS"
    , "\28216\12468", "\28216\26126"  -- Yu Gothic / Yu Mincho
    , "\12498\12521\12462\12494"      -- Hiragino
    ]
  EncCp950 ->
    [ "\26032\32048\26126\39636", "\32048\26126\39636"  -- MingLiU
    , "\27161\26999\39636"            -- DFKai-SB
    , "\24494\36575\27491\40657\39636" -- Microsoft JhengHei
    , "\33775\24247", "\25991\40718"  -- DynaFont, Arphic
    ]
  _ -> []

-- | Kana are decisive for Japanese: a CP932 stream misread as CP936 yields
-- ideographs, never kana, so their presence settles the two apart.
isKanaChar :: Char -> Bool
isKanaChar ch = code >= 0x3040 && code <= 0x30ff
  where code = ord ch

-- | Reward real CJK, punish the artefacts of a wrong guess -- private-use
-- characters and half-width katakana are what mis-decoded double-byte text
-- turns into.
textPlausibility :: String -> Int
textPlausibility = sum . map score
  where
    score ch
      | inRange 0x4e00 0x9fff || inRange 0x3040 0x30ff || inRange 0x3000 0x303f = 1
      | inRange 0xe000 0xf8ff || inRange 0xff61 0xff9f || code == 0xfffd = -2
      | otherwise = 0
      where
        code = ord ch
        inRange lo hi = code >= lo && code <= hi

-- | Fraction (in percent) of high bytes sitting in runs of two or more.
-- Genuine double-byte text is ~100%; CP1252 text, where accents and degree
-- signs stand between ASCII, is ~0%.  A design mixing both lands in between and
-- is not safe to force either way, so it keeps the CP1252 default.
highByteRunPercent :: [BS.ByteString] -> Int
highByteRunPercent strings
  | total == 0 = 0
  | otherwise = inRuns * 100 `div` total
  where
    (total, inRuns) = foldl accumulate (0, 0) strings
    accumulate totals raw = finish (foldl step (totals, 0) (BS.unpack raw))
    step ((seen, runs), run) byte
      | byte >= 0x80 = ((seen + 1, runs), run + 1)
      | run >= 2 = ((seen, runs + run), 0)
      | otherwise = ((seen, runs), 0)
    finish ((seen, runs), run)
      | run >= 2 = (seen, runs + run)
      | otherwise = (seen, runs)

-- | Pick the codepage the Library pool is written in.
--
-- The file records it nowhere -- there is no OLE SummaryInformation stream and
-- the style records' LOGFONT lfCharSet stays ANSI/SYMBOL even on CJK designs --
-- so it has to be inferred:
--
--   1. an explicit --source-encoding always wins;
--   2. a pool that is valid UTF-8 throughout is UTF-8;
--   3. otherwise the font names decide, being a small closed vocabulary that
--      reads as a real font in exactly one codepage;
--   4. with no font evidence, a pool whose high bytes are overwhelmingly
--      paired is double-byte, and among the codepages that decode it whole the
--      most plausible wins;
--   5. failing all that, CP1252.
--
-- Content alone is deliberately never enough to choose a double-byte codepage:
-- "0\176C" is also valid GBK (as "0\30408"), so sniffing would corrupt correct
-- Western text.  Step 4 needs the pairing evidence before it will consider one.
detectSourceEncoding :: Maybe SourceEncoding -> Maybe BS.ByteString -> SourceEncoding
detectSourceEncoding (Just chosen) _ = chosen
detectSourceEncoding Nothing Nothing = EncCp1252
detectSourceEncoding Nothing (Just body)
  | null highPool && null highFaces = EncCp1252
  | not (null highPool) && all (isJust . decodeUtf8Strict) highPool = EncUtf8
  | Just best <- bestByFontName = best
  | highByteRunPercent highPool >= 75 = byContent
  | otherwise = EncCp1252
  where
    highPool = [s | s <- libraryRawStrings body, BS.any (>= 0x80) s]
    highFaces = libraryFaceNameBytes body
    candidates = [EncCp932, EncCp936, EncCp950]

    fontScore :: SourceEncoding -> Int
    fontScore enc = sum (map (faceScore enc) highFaces)

    faceScore :: SourceEncoding -> BS.ByteString -> Int
    faceScore enc raw =
      case codepageTableFor enc >>= \table -> decodeCodepage table raw of
        Nothing -> 0
        Just decoded ->
          (if any (`isInfixOf` decoded) (knownFaceNames enc) then 100 else 0)
          + (if enc == EncCp932 && any isKanaChar decoded then 50 else 0)

    bestByFontName =
      case sortOn (negate . snd) [(enc, fontScore enc) | enc <- candidates] of
        (enc, score) : _ | score > 0 -> Just enc
        _ -> Nothing

    decodesWhole enc =
      all (\raw -> isJust (codepageTableFor enc >>= \t -> decodeCodepage t raw))
        highPool
    poolPlausibility enc = sum
      [ maybe 0 textPlausibility (codepageTableFor enc >>= \t -> decodeCodepage t raw)
      | raw <- highPool
      ]

    byContent = case filter decodesWhole candidates of
      [only] -> only
      viable@(_ : _ : _) ->
        case sortOn (negate . poolPlausibility) viable of
          first : second : _
            | poolPlausibility first > poolPlausibility second -> first
          _ -> EncCp1252
      _ -> EncCp1252

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

commonStringPrefix :: [String] -> String
commonStringPrefix [] = ""
commonStringPrefix (first:rest) = foldl commonPrefix first rest
  where
    commonPrefix left right = map fst $ takeWhile (uncurry (==)) (zip left right)

trimTrailingUnderscores :: String -> String
trimTrailingUnderscores = reverse . dropWhile (== '_') . reverse

componentUnitInfo :: MultiUnitRegistry -> String -> (String, Int)
componentUnitInfo registry cellName =
  Map.findWithDefault (cellName, 1) cellName (multiUnitCells registry)

componentLibName :: Options -> MultiUnitRegistry -> String -> String
componentLibName opts registry cellName
  | optKicadRc opts && cellName `elem` ["R", "C"] = "Device:" ++ cellName
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

dedupeConsecutive :: Eq a => [a] -> [a]
dedupeConsecutive [] = []
dedupeConsecutive (x:xs) = x : go x xs
  where
    go _ [] = []
    go prev (value:rest)
      | value == prev = go prev rest
      | otherwise = value : go value rest

findCellMatches :: BS.ByteString -> [(Int, Int, String)]
findCellMatches body =
  sortOn (\(start, _, _) -> start) $
    findForToken (BSC.pack ".Normal\0") ++ findForToken (BSC.pack ".Convert\0")
  where
    findForToken token =
      [ (cellStart, tokenPos + BS.length token, BSC.unpack (BS.take (tokenPos - cellStart) (BS.drop cellStart body)))
      | tokenPos <- findAll token body
      , let cellStart = rewindCellName tokenPos
      , cellStart < tokenPos
      ]

    rewindCellName pos
      | pos <= 0 = 0
      | otherwise =
          case byteAt body (pos - 1) of
            Just b | isCellChar b -> rewindCellName (pos - 1)
            _ -> pos

isCellChar :: Word8 -> Bool
isCellChar b =
  let c = toEnum (fromIntegral b) :: Char
  in isAlphaNum c || c `elem` ("_./+#-()" :: String)

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
  -> Options
  -> String
  -> Map.Map String CacheSymbol
  -> MultiUnitRegistry
  -> Map.Map (FilePath, Int) String
  -> [TextStyle]
  -> Int
  -> Int
  -> Page
  -> String
generatePageSch uuidSeed opts _project cacheSymbols multiUnits powerRefs textStyles pageIndex pageCount page =
  renderKicad $
    kNode "kicad_sch" $
      [ kNode "version" [kInt 20260306]
      , kNode "generator" [kString "dsn2kicad"]
      , kNode "generator_version" [kString "0.1"]
      , kUuid (pageObjectUuid uuidSeed page 0 1)
      , kNode "paper" [kString (pagePaper page)]
      , emitTitleBlock
      , kNode "lib_symbols"
          (emitSymbolDefinitions opts cacheSymbols multiUnits
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
      defaultComponentTextStyle (optKicadFonts opts) textStyles

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
      , not (optKicadRc opts && compCell component `elem` ["R", "C"])
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
      , optKicadRc opts
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
      , optKicadRc opts
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
          libName = componentLibName opts multiUnits (compCell comp)
          pinNumbers = if optKicadRc opts && compCell comp `elem` ["R", "C"]
            then ["1", "2"]
            else unique (map pinNumber (cachePins symbol))
          angle = componentAngleFor opts comp
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
                Just field -> componentFieldAt opts comp field value fieldSize
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
            [ kNode "lib_id" [kString ("power:" ++ powerLibName opts symbol)]
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
          atExpr = case powerValueCenter (optKicadFonts opts)
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
        size = pageTextSize (optKicadFonts opts) pageText style textLines rotation

    emitTextLine textIndex lineIndex lineText pageText style size rotation x y =
      let face = if optKicadFonts opts then "" else maybe "" textStyleFace style
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
  :: Options -> Map.Map String CacheSymbol -> MultiUnitRegistry -> [Page] -> String
generateSymbolLibrary opts cacheSymbols multiUnits pages =
  renderKicad $
    kNode "kicad_symbol_lib" $
      [ kNode "version" [kInt 20251024]
      , kNode "generator" [kString "dsn2kicad"]
      , kNode "generator_version" [kString "0.1"]
      ]
      ++ emitSymbolDefinitions opts cacheSymbols multiUnits
           [comp | page <- pages, comp <- pageComponents page]
           [symbol | page <- pages, symbol <- pagePowerSymbols page]

-- Symbol definitions for a set of placed components and power symbols: one
-- definition per referenced component cell, then one per power glyph.  A page's
-- embedded `lib_symbols` cache and the project-wide .kicad_sym are the same
-- list; they differ only in whether the scope is one page or all of them.
emitSymbolDefinitions
  :: Options
  -> Map.Map String CacheSymbol
  -> MultiUnitRegistry
  -> [Component]
  -> [PowerSymbol]
  -> [KExpr]
emitSymbolDefinitions opts cacheSymbols multiUnits components powerSymbols =
  map emitUsedSymbol usedCells ++ map emitPowerDefinition powerDefinitions
  where
    usedCells = Map.elems $ Map.fromListWith (\_ earlier -> earlier)
      [ (componentLibName opts multiUnits (compCell comp), compCell comp)
      | comp <- components
      ]

    emitUsedSymbol cellName
      | optKicadRc opts && cellName `elem` ["R", "C"] =
          libStandardDeviceSymbol cellName
      | otherwise =
          let (libName, _) = componentUnitInfo multiUnits cellName
          in case Map.lookup libName (multiUnitGroups multiUnits) of
               Just units -> libMultiUnitSymbol libName units cacheSymbols
               Nothing -> libSymbol
                 (libName, Map.findWithDefault emptyCacheSymbol libName cacheSymbols)

    powerDefinitions = Map.toAscList $ Map.fromListWith preferPowerStyle
      [ (powerLibName opts symbol, powerStyle symbol)
      | symbol <- powerSymbols
      , not (null (powerNetName symbol))
      ]

    preferPowerStyle PowerGround _ = PowerGround
    preferPowerStyle _ PowerGround = PowerGround
    preferPowerStyle new _ = new

    emitPowerDefinition (name, style)
      | optKicadPower opts = libStandardPowerSymbol name
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

powerLibName :: Options -> PowerSymbol -> String
powerLibName opts symbol
  | not (optKicadPower opts) = powerNetName symbol
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

componentAngleFor :: Options -> Component -> Int
componentAngleFor opts component
  | optKicadRc opts && compCell component `elem` ["R", "C"] =
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
  :: Options -> Component -> DisplayField -> String -> Double
  -> String -> Bool -> Bool -> KExpr
componentFieldAt opts component field value size face bold italic =
  kAt [kDouble centerX, kDouble centerY, kInt relativeAngle]
  where
    absoluteAngle = displayTextAngle field `mod` 360
    relative = (absoluteAngle - componentAngleFor opts component) `mod` 360
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
      orcadTextTopLeftToCenter (optKicadFonts opts) value size face bold italic
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

stableObjectUuid :: BS.ByteString -> Int -> Int -> String
stableObjectUuid seed category objectIndex =
  deterministicUuid seed (show category ++ ":" ++ show objectIndex)

-- Seed every output from the DSN digest alone.  Explicit object keys include
-- stable page/stream identity, so source and output filenames need not be part
-- of the seed and renaming the input does not churn UUIDs.
deterministicUuid :: BS.ByteString -> String -> String
deterministicUuid seed objectKey =
  formatUuid $ setUuidVersionAndVariant $ BS.take 16 $
    sha256 (seed <> BS.singleton 0 <> utf8Encode objectKey)

setUuidVersionAndVariant :: BS.ByteString -> BS.ByteString
setUuidVersionAndVariant bytes = BS.pack
  [ case index of
      6 -> (value .&. 0x0f) .|. 0x40
      8 -> (value .&. 0x3f) .|. 0x80
      _ -> value
  | (index, value) <- zip [0 :: Int ..] (BS.unpack bytes)
  ]

formatUuid :: BS.ByteString -> String
formatUuid bytes =
  intercalate "-"
    [ take 8 rendered
    , take 4 (drop 8 rendered)
    , take 4 (drop 12 rendered)
    , take 4 (drop 16 rendered)
    , take 12 (drop 20 rendered)
    ]
  where
    rendered = concatMap hexByte (BS.unpack bytes)
    hexByte value =
      let digits = showHex value ""
      in replicate (2 - length digits) '0' ++ digits

utf8Encode :: String -> BS.ByteString
utf8Encode = BS.pack . concatMap encodeChar
  where
    encodeChar :: Char -> [Word8]
    encodeChar char
      | code <= 0x7f =
          [fromIntegral code]
      | code <= 0x7ff =
          [ fromIntegral (0xc0 .|. (code `shiftR` 6))
          , fromIntegral (0x80 .|. (code .&. 0x3f))
          ]
      | code >= 0xd800 && code <= 0xdfff =
          encodeCodePoint 0xfffd
      | code <= 0xffff =
          encodeCodePoint code
      | otherwise =
          [ fromIntegral (0xf0 .|. (code `shiftR` 18))
          , fromIntegral (0x80 .|. ((code `shiftR` 12) .&. 0x3f))
          , fromIntegral (0x80 .|. ((code `shiftR` 6) .&. 0x3f))
          , fromIntegral (0x80 .|. (code .&. 0x3f))
          ]
      where
        code = ord char

    encodeCodePoint :: Int -> [Word8]
    encodeCodePoint code =
      [ fromIntegral (0xe0 .|. (code `shiftR` 12))
      , fromIntegral (0x80 .|. ((code `shiftR` 6) .&. 0x3f))
      , fromIntegral (0x80 .|. (code .&. 0x3f))
      ]

type Sha256State =
  (Word32, Word32, Word32, Word32, Word32, Word32, Word32, Word32)

sha256 :: BS.ByteString -> BS.ByteString
sha256 input = BS.concat (map word32Be finalWords)
  where
    bitLength = fromIntegral (BS.length input) * 8 :: Word64
    paddingLength = (56 - ((BS.length input + 1) `mod` 64)) `mod` 64
    padded =
      input
      <> BS.singleton 0x80
      <> BS.replicate paddingLength 0
      <> word64Be bitLength
    blocks =
      [ BS.take 64 (BS.drop offset padded)
      | offset <- [0, 64 .. BS.length padded - 64]
      ]
    initialState =
      ( 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
      , 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
      )
    finalWords = stateWords (List.foldl' compressSha256 initialState blocks)

compressSha256 :: Sha256State -> BS.ByteString -> Sha256State
compressSha256 initial block = addSha256States initial compressed
  where
    schedule :: Array Int Word32
    schedule = array (0, 63) $
      [ (index, word32BeAt block (index * 4))
      | index <- [0..15]
      ]
      ++
      [ ( index
        , smallSigma1 (schedule ! (index - 2))
          + schedule ! (index - 7)
          + smallSigma0 (schedule ! (index - 15))
          + schedule ! (index - 16)
        )
      | index <- [16..63]
      ]

    compressed = List.foldl' roundSha256 initial [0..63]
    roundSha256 (a, b, c, d, e, f, g, h) index =
      let choice = (e .&. f) `xor` (complement e .&. g)
          majority = (a .&. b) `xor` (a .&. c) `xor` (b .&. c)
          temporary1 =
            h + bigSigma1 e + choice + sha256Constants ! index
            + schedule ! index
          temporary2 = bigSigma0 a + majority
      in (temporary1 + temporary2, a, b, c, d + temporary1, e, f, g)

smallSigma0, smallSigma1, bigSigma0, bigSigma1 :: Word32 -> Word32
smallSigma0 value =
  rotateR value 7 `xor` rotateR value 18 `xor` shiftR value 3
smallSigma1 value =
  rotateR value 17 `xor` rotateR value 19 `xor` shiftR value 10
bigSigma0 value =
  rotateR value 2 `xor` rotateR value 13 `xor` rotateR value 22
bigSigma1 value =
  rotateR value 6 `xor` rotateR value 11 `xor` rotateR value 25

addSha256States :: Sha256State -> Sha256State -> Sha256State
addSha256States
  (a, b, c, d, e, f, g, h)
  (a', b', c', d', e', f', g', h') =
    (a + a', b + b', c + c', d + d', e + e', f + f', g + g', h + h')

stateWords :: Sha256State -> [Word32]
stateWords (a, b, c, d, e, f, g, h) = [a, b, c, d, e, f, g, h]

word32BeAt :: BS.ByteString -> Int -> Word32
word32BeAt bytes off =
  fromIntegral (BS.index bytes off) `shiftL` 24
  .|. fromIntegral (BS.index bytes (off + 1)) `shiftL` 16
  .|. fromIntegral (BS.index bytes (off + 2)) `shiftL` 8
  .|. fromIntegral (BS.index bytes (off + 3))

word32Be :: Word32 -> BS.ByteString
word32Be value = BS.pack
  [ fromIntegral (value `shiftR` 24)
  , fromIntegral (value `shiftR` 16)
  , fromIntegral (value `shiftR` 8)
  , fromIntegral value
  ]

word64Be :: Word64 -> BS.ByteString
word64Be value = BS.pack
  [ fromIntegral (value `shiftR` shift)
  | shift <- [56, 48 .. 0]
  ]

sha256Constants :: Array Int Word32
sha256Constants = listArray (0, 63)
  [ 0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5
  , 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5
  , 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3
  , 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174
  , 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc
  , 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da
  , 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7
  , 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967
  , 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13
  , 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85
  , 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3
  , 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070
  , 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5
  , 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3
  , 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208
  , 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
  ]

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

unique :: Ord a => [a] -> [a]
unique = go Map.empty
  where
    go _ [] = []
    go seen (x:xs)
      | Map.member x seen = go seen xs
      | otherwise = x : go (Map.insert x () seen) xs

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

extractStrings :: BS.ByteString -> Int -> [(Int, String)]
extractStrings body minLen = finish (BS.length body) [] [] 0 (BS.unpack body)
  where
    finish _pos acc current start [] =
      let acc' = if length current >= minLen then (start, reverse current) : acc else acc
      in reverse acc'
    finish pos acc current start (b:bs)
      | isPrintableAscii b =
          let start' = if null current then pos else start
          in finish (pos + 1) acc (byteToChar b : current) start' bs
      | otherwise =
          let acc' = if length current >= minLen then (start, reverse current) : acc else acc
          in finish (pos + 1) acc' [] (pos + 1) bs

asciiAt :: BS.ByteString -> Int -> Int -> Maybe String
asciiAt body off len = do
  guard (off >= 0 && len >= 0 && off + len <= BS.length body)
  let chunk = BS.take len (BS.drop off body)
  guard (BS.all isPrintableAscii chunk)
  pure (BSC.unpack chunk)

asciiPrefixAt :: BS.ByteString -> Int -> Int -> String
asciiPrefixAt body off maxLen =
  BSC.unpack $ BS.takeWhile isPrintableAscii $ BS.take maxLen $ BS.drop off body

isPrintableAscii :: Word8 -> Bool
isPrintableAscii b = b >= 32 && b < 127

byteToChar :: Word8 -> Char
byteToChar = toEnum . fromIntegral

byteAt :: BS.ByteString -> Int -> Maybe Word8
byteAt body off
  | off >= 0 && off < BS.length body = Just (BS.index body off)
  | otherwise = Nothing

word16LE :: BS.ByteString -> Int -> Maybe Word16
word16LE body off = do
  b0 <- byteAt body off
  b1 <- byteAt body (off + 1)
  pure $ fromIntegral b0 + fromIntegral b1 * 0x100

word32LE :: BS.ByteString -> Int -> Maybe Word32
word32LE body off = do
  b0 <- byteAt body off
  b1 <- byteAt body (off + 1)
  b2 <- byteAt body (off + 2)
  b3 <- byteAt body (off + 3)
  pure $
    fromIntegral b0
    + fromIntegral b1 * 0x100
    + fromIntegral b2 * 0x10000
    + fromIntegral b3 * 0x1000000

word64LE :: BS.ByteString -> Int -> Maybe Word64
word64LE body off = do
  b0 <- byteAt body off
  b1 <- byteAt body (off + 1)
  b2 <- byteAt body (off + 2)
  b3 <- byteAt body (off + 3)
  b4 <- byteAt body (off + 4)
  b5 <- byteAt body (off + 5)
  b6 <- byteAt body (off + 6)
  b7 <- byteAt body (off + 7)
  pure $
    fromIntegral b0
    + fromIntegral b1 * 0x100
    + fromIntegral b2 * 0x10000
    + fromIntegral b3 * 0x1000000
    + fromIntegral b4 * 0x100000000
    + fromIntegral b5 * 0x10000000000
    + fromIntegral b6 * 0x1000000000000
    + fromIntegral b7 * 0x100000000000000

int16LE :: BS.ByteString -> Int -> Maybe Int
int16LE body off = fromIntegral . (fromIntegral :: Word16 -> Int16) <$> word16LE body off

int32LE :: BS.ByteString -> Int -> Maybe Int
int32LE body off = fromIntegral . (fromIntegral :: Word32 -> Int32) <$> word32LE body off

readI32Quad :: BS.ByteString -> Int -> Maybe (Int, Int, Int, Int)
readI32Quad body off = do
  x1 <- int32LE body off
  y1 <- int32LE body (off + 4)
  x2 <- int32LE body (off + 8)
  y2 <- int32LE body (off + 12)
  pure (x1, y1, x2, y2)

readI32Oct :: BS.ByteString -> Int -> Maybe (Int, Int, Int, Int, Int, Int, Int, Int)
readI32Oct body off = do
  x1 <- int32LE body off
  y1 <- int32LE body (off + 4)
  x2 <- int32LE body (off + 8)
  y2 <- int32LE body (off + 12)
  x3 <- int32LE body (off + 16)
  y3 <- int32LE body (off + 20)
  x4 <- int32LE body (off + 24)
  y4 <- int32LE body (off + 28)
  pure (x1, y1, x2, y2, x3, y3, x4, y4)

findSubFrom :: BS.ByteString -> Int -> BS.ByteString -> Maybe Int
findSubFrom needle start haystack
  | BS.null needle = Just start
  | start < 0 || start > BS.length haystack = Nothing
  | otherwise =
      let (before, after) = BS.breakSubstring needle (BS.drop start haystack)
      in if BS.null after
         then Nothing
         else Just (start + BS.length before)

findSubBefore :: BS.ByteString -> Int -> Int -> BS.ByteString -> Maybe Int
findSubBefore needle start end haystack = do
  idx <- findSubFrom needle start haystack
  guard (idx < end)
  pure idx

findAll :: BS.ByteString -> BS.ByteString -> [Int]
findAll needle = findAllFrom needle 0

findAllFrom :: BS.ByteString -> Int -> BS.ByteString -> [Int]
findAllFrom needle start haystack =
  case findSubFrom needle start haystack of
    Nothing -> []
    Just idx -> idx : findAllFrom needle (idx + 1) haystack

firstJust :: [Maybe a] -> Maybe a
firstJust [] = Nothing
firstJust (x:xs) = case x of
  Just _ -> x
  Nothing -> firstJust xs

lookupList :: [a] -> Int -> Maybe a
lookupList values index
  | index < 0 = Nothing
  | otherwise = case drop index values of
      value : _ -> Just value
      [] -> Nothing

listAt :: [a] -> Int -> Maybe a
listAt = lookupList

orElse :: Maybe a -> Maybe a -> Maybe a
orElse value@Just{} _ = value
orElse Nothing fallback = fallback


-- BEGIN GENERATED CODEPAGE TABLES -- AUTO-GENERATED, do not edit.
-- Regenerate via: python3 gen_codepage_tables.py
--
-- Windows ANSI codepage tables for decoding Library string-pool text.
-- Mappings are Python's own codecs, i.e. the standard Microsoft ones.
-- A slot holding U+FFFD is an unassigned byte sequence, which
-- decodeCodepage reports as a decode failure rather than substituting.

data Codepage = Codepage
  { cpName :: !String
  , cpLeadLo :: !Int
  , cpLeadHi :: !Int
  , cpTrailLo :: !Int
  , cpTrailHi :: !Int
  , cpSingle :: !(U.UArray Int Char)
  , cpDouble :: !(U.UArray Int Char)
  }

-- | Japanese (Shift-JIS).  68 single-byte and 9604 double-byte mappings.
cp932Table :: Codepage
cp932Table = Codepage
  { cpName = "cp932"
  , cpLeadLo = 0x81
  , cpLeadHi = 0xfc
  , cpTrailLo = 0x40
  , cpTrailHi = 0xfc
  , cpSingle = U.listArray (0, 127) "\128\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\63728｡｢｣､･ｦｧｨｩｪｫｬｭｮｯｰｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜﾝﾞﾟ\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\63729\63730\63731"
  , cpDouble = U.listArray (0, 23435) $ concat
      [ "\12288、。，．・：；？！゛゜´｀¨＾￣＿ヽヾゝゞ〃仝々〆〇ー―‐／＼～∥｜…‥‘’“”（）〔〕［］｛｝〈〉《》「」『』【】＋－±×\0÷＝≠＜＞≦≧∞∴♂♀°′″℃￥＄￠￡％＃＆＊＠§☆★○●◎◇◆□■△▲▽▼※〒→←↑↓〓\0\0\0\0\0\0\0\0\0\0\0∈∋⊆⊇⊂⊃∪∩\0\0\0\0\0\0\0\0∧∨￢⇒⇔∀∃\0\0\0\0\0\0\0\0\0\0\0∠⊥⌒∂∇≡≒≪≫√∽∝∵∫∬\0\0\0\0\0\0\0Å‰♯♭♪†‡¶\0\0\0\0◯" -- 0x81
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\&０１２３４５６７８９\0\0\0\0\0\0\0ＡＢＣＤＥＦＧＨＩＪＫＬＭＮＯＰＱＲＳＴＵＶＷＸＹＺ\0\0\0\0\0\0\0ａｂｃｄｅｆｇｈｉｊｋｌｍｎｏｐｑｒｓｔｕｖｗｘｙｚ\0\0\0\0ぁあぃいぅうぇえぉおかがきぎくぐけげこごさざしじすずせぜそぞただちぢっつづてでとどなにぬねのはばぱひびぴふぶぷへべぺほぼぽまみむめもゃやゅゆょよらりるれろゎわゐゑをん\0\0\0\0\0\0\0\0\0\0\0" -- 0x82
      , "ァアィイゥウェエォオカガキギクグケゲコゴサザシジスズセゼソゾタダチヂッツヅテデトドナニヌネノハバパヒビピフブプヘベペホボポマミ\0ムメモャヤュユョヨラリルレロヮワヰヱヲンヴヵヶ\0\0\0\0\0\0\0\0ΑΒΓΔΕΖΗΘΙΚΛΜΝΞΟΠΡΣΤΥΦΧΨΩ\0\0\0\0\0\0\0\0αβγδεζηθικλμνξοπρστυφχψω\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0x83
      , "АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0абвгдеёжзийклмн\0опрстуфхцчшщъыьэюя\0\0\0\0\0\0\0\0\0\0\0\0\0─│┌┐┘└├┬┤┴┼━┃┏┓┛┗┣┳┫┻╋┠┯┨┷┿┝┰┥┸╂\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0x84
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0x85
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0x86
      , "①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳ⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩ\0㍉㌔㌢㍍㌘㌧㌃㌶㍑㍗㌍㌦㌣㌫㍊㌻㎜㎝㎞㎎㎏㏄㎡\0\0\0\0\0\0\0\0㍻\0〝〟№㏍℡㊤㊥㊦㊧㊨㈱㈲㈹㍾㍽㍼≒≡∫∮∑√⊥∠∟⊿∵∩∪\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0x87
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0亜唖娃阿哀愛挨姶逢葵茜穐悪握渥旭葦芦鯵梓圧斡扱宛姐虻飴絢綾鮎或粟袷安庵按暗案闇鞍杏以伊位依偉囲夷委威尉惟意慰易椅為畏異移維緯胃萎衣謂違遺医井亥域育郁磯一壱溢逸稲茨芋鰯允印咽員因姻引飲淫胤蔭" -- 0x88
      , "院陰隠韻吋右宇烏羽迂雨卯鵜窺丑碓臼渦嘘唄欝蔚鰻姥厩浦瓜閏噂云運雲荏餌叡営嬰影映曳栄永泳洩瑛盈穎頴英衛詠鋭液疫益駅悦謁越閲榎厭円\0園堰奄宴延怨掩援沿演炎焔煙燕猿縁艶苑薗遠鉛鴛塩於汚甥凹央奥往応押旺横欧殴王翁襖鴬鴎黄岡沖荻億屋憶臆桶牡乙俺卸恩温穏音下化仮何伽価佳加可嘉夏嫁家寡科暇果架歌河火珂禍禾稼箇花苛茄荷華菓蝦課嘩貨迦過霞蚊俄峨我牙画臥芽蛾賀雅餓駕介会解回塊壊廻快怪悔恢懐戒拐改" -- 0x89
      , "魁晦械海灰界皆絵芥蟹開階貝凱劾外咳害崖慨概涯碍蓋街該鎧骸浬馨蛙垣柿蛎鈎劃嚇各廓拡撹格核殻獲確穫覚角赫較郭閣隔革学岳楽額顎掛笠樫\0橿梶鰍潟割喝恰括活渇滑葛褐轄且鰹叶椛樺鞄株兜竃蒲釜鎌噛鴨栢茅萱粥刈苅瓦乾侃冠寒刊勘勧巻喚堪姦完官寛干幹患感慣憾換敢柑桓棺款歓汗漢澗潅環甘監看竿管簡緩缶翰肝艦莞観諌貫還鑑間閑関陥韓館舘丸含岸巌玩癌眼岩翫贋雁頑顔願企伎危喜器基奇嬉寄岐希幾忌揮机旗既期棋棄" -- 0x8a
      , "機帰毅気汽畿祈季稀紀徽規記貴起軌輝飢騎鬼亀偽儀妓宜戯技擬欺犠疑祇義蟻誼議掬菊鞠吉吃喫桔橘詰砧杵黍却客脚虐逆丘久仇休及吸宮弓急救\0朽求汲泣灸球究窮笈級糾給旧牛去居巨拒拠挙渠虚許距鋸漁禦魚亨享京供侠僑兇競共凶協匡卿叫喬境峡強彊怯恐恭挟教橋況狂狭矯胸脅興蕎郷鏡響饗驚仰凝尭暁業局曲極玉桐粁僅勤均巾錦斤欣欽琴禁禽筋緊芹菌衿襟謹近金吟銀九倶句区狗玖矩苦躯駆駈駒具愚虞喰空偶寓遇隅串櫛釧屑屈" -- 0x8b
      , "掘窟沓靴轡窪熊隈粂栗繰桑鍬勲君薫訓群軍郡卦袈祁係傾刑兄啓圭珪型契形径恵慶慧憩掲携敬景桂渓畦稽系経継繋罫茎荊蛍計詣警軽頚鶏芸迎鯨\0劇戟撃激隙桁傑欠決潔穴結血訣月件倹倦健兼券剣喧圏堅嫌建憲懸拳捲検権牽犬献研硯絹県肩見謙賢軒遣鍵険顕験鹸元原厳幻弦減源玄現絃舷言諺限乎個古呼固姑孤己庫弧戸故枯湖狐糊袴股胡菰虎誇跨鈷雇顧鼓五互伍午呉吾娯後御悟梧檎瑚碁語誤護醐乞鯉交佼侯候倖光公功効勾厚口向" -- 0x8c
      , "后喉坑垢好孔孝宏工巧巷幸広庚康弘恒慌抗拘控攻昂晃更杭校梗構江洪浩港溝甲皇硬稿糠紅紘絞綱耕考肯肱腔膏航荒行衡講貢購郊酵鉱砿鋼閤降\0項香高鴻剛劫号合壕拷濠豪轟麹克刻告国穀酷鵠黒獄漉腰甑忽惚骨狛込此頃今困坤墾婚恨懇昏昆根梱混痕紺艮魂些佐叉唆嵯左差査沙瑳砂詐鎖裟坐座挫債催再最哉塞妻宰彩才採栽歳済災采犀砕砦祭斎細菜裁載際剤在材罪財冴坂阪堺榊肴咲崎埼碕鷺作削咋搾昨朔柵窄策索錯桜鮭笹匙冊刷" -- 0x8d
      , "察拶撮擦札殺薩雑皐鯖捌錆鮫皿晒三傘参山惨撒散桟燦珊産算纂蚕讃賛酸餐斬暫残仕仔伺使刺司史嗣四士始姉姿子屍市師志思指支孜斯施旨枝止\0死氏獅祉私糸紙紫肢脂至視詞詩試誌諮資賜雌飼歯事似侍児字寺慈持時次滋治爾璽痔磁示而耳自蒔辞汐鹿式識鴫竺軸宍雫七叱執失嫉室悉湿漆疾質実蔀篠偲柴芝屡蕊縞舎写射捨赦斜煮社紗者謝車遮蛇邪借勺尺杓灼爵酌釈錫若寂弱惹主取守手朱殊狩珠種腫趣酒首儒受呪寿授樹綬需囚収周" -- 0x8e
      , "宗就州修愁拾洲秀秋終繍習臭舟蒐衆襲讐蹴輯週酋酬集醜什住充十従戎柔汁渋獣縦重銃叔夙宿淑祝縮粛塾熟出術述俊峻春瞬竣舜駿准循旬楯殉淳\0準潤盾純巡遵醇順処初所暑曙渚庶緒署書薯藷諸助叙女序徐恕鋤除傷償勝匠升召哨商唱嘗奨妾娼宵将小少尚庄床廠彰承抄招掌捷昇昌昭晶松梢樟樵沼消渉湘焼焦照症省硝礁祥称章笑粧紹肖菖蒋蕉衝裳訟証詔詳象賞醤鉦鍾鐘障鞘上丈丞乗冗剰城場壌嬢常情擾条杖浄状畳穣蒸譲醸錠嘱埴飾" -- 0x8f
      , "拭植殖燭織職色触食蝕辱尻伸信侵唇娠寝審心慎振新晋森榛浸深申疹真神秦紳臣芯薪親診身辛進針震人仁刃塵壬尋甚尽腎訊迅陣靭笥諏須酢図厨\0逗吹垂帥推水炊睡粋翠衰遂酔錐錘随瑞髄崇嵩数枢趨雛据杉椙菅頗雀裾澄摺寸世瀬畝是凄制勢姓征性成政整星晴棲栖正清牲生盛精聖声製西誠誓請逝醒青静斉税脆隻席惜戚斥昔析石積籍績脊責赤跡蹟碩切拙接摂折設窃節説雪絶舌蝉仙先千占宣専尖川戦扇撰栓栴泉浅洗染潜煎煽旋穿箭線" -- 0x90
      , "繊羨腺舛船薦詮賎践選遷銭銑閃鮮前善漸然全禅繕膳糎噌塑岨措曾曽楚狙疏疎礎祖租粗素組蘇訴阻遡鼠僧創双叢倉喪壮奏爽宋層匝惣想捜掃挿掻\0操早曹巣槍槽漕燥争痩相窓糟総綜聡草荘葬蒼藻装走送遭鎗霜騒像増憎臓蔵贈造促側則即息捉束測足速俗属賊族続卒袖其揃存孫尊損村遜他多太汰詑唾堕妥惰打柁舵楕陀駄騨体堆対耐岱帯待怠態戴替泰滞胎腿苔袋貸退逮隊黛鯛代台大第醍題鷹滝瀧卓啄宅托択拓沢濯琢託鐸濁諾茸凧蛸只" -- 0x91
      , "叩但達辰奪脱巽竪辿棚谷狸鱈樽誰丹単嘆坦担探旦歎淡湛炭短端箪綻耽胆蛋誕鍛団壇弾断暖檀段男談値知地弛恥智池痴稚置致蜘遅馳築畜竹筑蓄\0逐秩窒茶嫡着中仲宙忠抽昼柱注虫衷註酎鋳駐樗瀦猪苧著貯丁兆凋喋寵帖帳庁弔張彫徴懲挑暢朝潮牒町眺聴脹腸蝶調諜超跳銚長頂鳥勅捗直朕沈珍賃鎮陳津墜椎槌追鎚痛通塚栂掴槻佃漬柘辻蔦綴鍔椿潰坪壷嬬紬爪吊釣鶴亭低停偵剃貞呈堤定帝底庭廷弟悌抵挺提梯汀碇禎程締艇訂諦蹄逓" -- 0x92
      , "邸鄭釘鼎泥摘擢敵滴的笛適鏑溺哲徹撤轍迭鉄典填天展店添纏甜貼転顛点伝殿澱田電兎吐堵塗妬屠徒斗杜渡登菟賭途都鍍砥砺努度土奴怒倒党冬\0凍刀唐塔塘套宕島嶋悼投搭東桃梼棟盗淘湯涛灯燈当痘祷等答筒糖統到董蕩藤討謄豆踏逃透鐙陶頭騰闘働動同堂導憧撞洞瞳童胴萄道銅峠鴇匿得徳涜特督禿篤毒独読栃橡凸突椴届鳶苫寅酉瀞噸屯惇敦沌豚遁頓呑曇鈍奈那内乍凪薙謎灘捺鍋楢馴縄畷南楠軟難汝二尼弐迩匂賑肉虹廿日乳入" -- 0x93
      , "如尿韮任妊忍認濡禰祢寧葱猫熱年念捻撚燃粘乃廼之埜嚢悩濃納能脳膿農覗蚤巴把播覇杷波派琶破婆罵芭馬俳廃拝排敗杯盃牌背肺輩配倍培媒梅\0楳煤狽買売賠陪這蝿秤矧萩伯剥博拍柏泊白箔粕舶薄迫曝漠爆縛莫駁麦函箱硲箸肇筈櫨幡肌畑畠八鉢溌発醗髪伐罰抜筏閥鳩噺塙蛤隼伴判半反叛帆搬斑板氾汎版犯班畔繁般藩販範釆煩頒飯挽晩番盤磐蕃蛮匪卑否妃庇彼悲扉批披斐比泌疲皮碑秘緋罷肥被誹費避非飛樋簸備尾微枇毘琵眉美" -- 0x94
      , "鼻柊稗匹疋髭彦膝菱肘弼必畢筆逼桧姫媛紐百謬俵彪標氷漂瓢票表評豹廟描病秒苗錨鋲蒜蛭鰭品彬斌浜瀕貧賓頻敏瓶不付埠夫婦富冨布府怖扶敷\0斧普浮父符腐膚芙譜負賦赴阜附侮撫武舞葡蕪部封楓風葺蕗伏副復幅服福腹複覆淵弗払沸仏物鮒分吻噴墳憤扮焚奮粉糞紛雰文聞丙併兵塀幣平弊柄並蔽閉陛米頁僻壁癖碧別瞥蔑箆偏変片篇編辺返遍便勉娩弁鞭保舗鋪圃捕歩甫補輔穂募墓慕戊暮母簿菩倣俸包呆報奉宝峰峯崩庖抱捧放方朋" -- 0x95
      , "法泡烹砲縫胞芳萌蓬蜂褒訪豊邦鋒飽鳳鵬乏亡傍剖坊妨帽忘忙房暴望某棒冒紡肪膨謀貌貿鉾防吠頬北僕卜墨撲朴牧睦穆釦勃没殆堀幌奔本翻凡盆\0摩磨魔麻埋妹昧枚毎哩槙幕膜枕鮪柾鱒桝亦俣又抹末沫迄侭繭麿万慢満漫蔓味未魅巳箕岬密蜜湊蓑稔脈妙粍民眠務夢無牟矛霧鵡椋婿娘冥名命明盟迷銘鳴姪牝滅免棉綿緬面麺摸模茂妄孟毛猛盲網耗蒙儲木黙目杢勿餅尤戻籾貰問悶紋門匁也冶夜爺耶野弥矢厄役約薬訳躍靖柳薮鑓愉愈油癒" -- 0x96
      , "諭輸唯佑優勇友宥幽悠憂揖有柚湧涌猶猷由祐裕誘遊邑郵雄融夕予余与誉輿預傭幼妖容庸揚揺擁曜楊様洋溶熔用窯羊耀葉蓉要謡踊遥陽養慾抑欲\0沃浴翌翼淀羅螺裸来莱頼雷洛絡落酪乱卵嵐欄濫藍蘭覧利吏履李梨理璃痢裏裡里離陸律率立葎掠略劉流溜琉留硫粒隆竜龍侶慮旅虜了亮僚両凌寮料梁涼猟療瞭稜糧良諒遼量陵領力緑倫厘林淋燐琳臨輪隣鱗麟瑠塁涙累類令伶例冷励嶺怜玲礼苓鈴隷零霊麗齢暦歴列劣烈裂廉恋憐漣煉簾練聯" -- 0x97
      , "蓮連錬呂魯櫓炉賂路露労婁廊弄朗楼榔浪漏牢狼篭老聾蝋郎六麓禄肋録論倭和話歪賄脇惑枠鷲亙亘鰐詫藁蕨椀湾碗腕\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0弌丐丕个丱丶丼丿乂乖乘亂亅豫亊舒弍于亞亟亠亢亰亳亶从仍仄仆仂仗仞仭仟价伉佚估佛佝佗佇佶侈侏侘佻佩佰侑佯來侖儘俔俟俎俘俛俑俚俐俤俥倚倨倔倪倥倅伜俶倡倩倬俾俯們倆偃假會偕偐偈做偖偬偸傀傚傅傴傲" -- 0x98
      , "僉僊傳僂僖僞僥僭僣僮價僵儉儁儂儖儕儔儚儡儺儷儼儻儿兀兒兌兔兢竸兩兪兮冀冂囘册冉冏冑冓冕冖冤冦冢冩冪冫决冱冲冰况冽凅凉凛几處凩凭\0凰凵凾刄刋刔刎刧刪刮刳刹剏剄剋剌剞剔剪剴剩剳剿剽劍劔劒剱劈劑辨辧劬劭劼劵勁勍勗勞勣勦飭勠勳勵勸勹匆匈甸匍匐匏匕匚匣匯匱匳匸區卆卅丗卉卍凖卞卩卮夘卻卷厂厖厠厦厥厮厰厶參簒雙叟曼燮叮叨叭叺吁吽呀听吭吼吮吶吩吝呎咏呵咎呟呱呷呰咒呻咀呶咄咐咆哇咢咸咥咬哄哈咨" -- 0x99
      , "咫哂咤咾咼哘哥哦唏唔哽哮哭哺哢唹啀啣啌售啜啅啖啗唸唳啝喙喀咯喊喟啻啾喘喞單啼喃喩喇喨嗚嗅嗟嗄嗜嗤嗔嘔嗷嘖嗾嗽嘛嗹噎噐營嘴嘶嘲嘸\0噫噤嘯噬噪嚆嚀嚊嚠嚔嚏嚥嚮嚶嚴囂嚼囁囃囀囈囎囑囓囗囮囹圀囿圄圉圈國圍圓團圖嗇圜圦圷圸坎圻址坏坩埀垈坡坿垉垓垠垳垤垪垰埃埆埔埒埓堊埖埣堋堙堝塲堡塢塋塰毀塒堽塹墅墹墟墫墺壞墻墸墮壅壓壑壗壙壘壥壜壤壟壯壺壹壻壼壽夂夊夐夛梦夥夬夭夲夸夾竒奕奐奎奚奘奢奠奧奬奩" -- 0x9a
      , "奸妁妝佞侫妣妲姆姨姜妍姙姚娥娟娑娜娉娚婀婬婉娵娶婢婪媚媼媾嫋嫂媽嫣嫗嫦嫩嫖嫺嫻嬌嬋嬖嬲嫐嬪嬶嬾孃孅孀孑孕孚孛孥孩孰孳孵學斈孺宀\0它宦宸寃寇寉寔寐寤實寢寞寥寫寰寶寳尅將專對尓尠尢尨尸尹屁屆屎屓屐屏孱屬屮乢屶屹岌岑岔妛岫岻岶岼岷峅岾峇峙峩峽峺峭嶌峪崋崕崗嵜崟崛崑崔崢崚崙崘嵌嵒嵎嵋嵬嵳嵶嶇嶄嶂嶢嶝嶬嶮嶽嶐嶷嶼巉巍巓巒巖巛巫已巵帋帚帙帑帛帶帷幄幃幀幎幗幔幟幢幤幇幵并幺麼广庠廁廂廈廐廏" -- 0x9b
      , "廖廣廝廚廛廢廡廨廩廬廱廳廰廴廸廾弃弉彝彜弋弑弖弩弭弸彁彈彌彎弯彑彖彗彙彡彭彳彷徃徂彿徊很徑徇從徙徘徠徨徭徼忖忻忤忸忱忝悳忿怡恠\0怙怐怩怎怱怛怕怫怦怏怺恚恁恪恷恟恊恆恍恣恃恤恂恬恫恙悁悍惧悃悚悄悛悖悗悒悧悋惡悸惠惓悴忰悽惆悵惘慍愕愆惶惷愀惴惺愃愡惻惱愍愎慇愾愨愧慊愿愼愬愴愽慂慄慳慷慘慙慚慫慴慯慥慱慟慝慓慵憙憖憇憬憔憚憊憑憫憮懌懊應懷懈懃懆憺懋罹懍懦懣懶懺懴懿懽懼懾戀戈戉戍戌戔戛" -- 0x9c
      , "戞戡截戮戰戲戳扁扎扞扣扛扠扨扼抂抉找抒抓抖拔抃抔拗拑抻拏拿拆擔拈拜拌拊拂拇抛拉挌拮拱挧挂挈拯拵捐挾捍搜捏掖掎掀掫捶掣掏掉掟掵捫\0捩掾揩揀揆揣揉插揶揄搖搴搆搓搦搶攝搗搨搏摧摯摶摎攪撕撓撥撩撈撼據擒擅擇撻擘擂擱擧舉擠擡抬擣擯攬擶擴擲擺攀擽攘攜攅攤攣攫攴攵攷收攸畋效敖敕敍敘敞敝敲數斂斃變斛斟斫斷旃旆旁旄旌旒旛旙无旡旱杲昊昃旻杳昵昶昴昜晏晄晉晁晞晝晤晧晨晟晢晰暃暈暎暉暄暘暝曁暹曉暾暼" -- 0x9d
      , "曄暸曖曚曠昿曦曩曰曵曷朏朖朞朦朧霸朮朿朶杁朸朷杆杞杠杙杣杤枉杰枩杼杪枌枋枦枡枅枷柯枴柬枳柩枸柤柞柝柢柮枹柎柆柧檜栞框栩桀桍栲桎\0梳栫桙档桷桿梟梏梭梔條梛梃檮梹桴梵梠梺椏梍桾椁棊椈棘椢椦棡椌棍棔棧棕椶椒椄棗棣椥棹棠棯椨椪椚椣椡棆楹楷楜楸楫楔楾楮椹楴椽楙椰楡楞楝榁楪榲榮槐榿槁槓榾槎寨槊槝榻槃榧樮榑榠榜榕榴槞槨樂樛槿權槹槲槧樅榱樞槭樔槫樊樒櫁樣樓橄樌橲樶橸橇橢橙橦橈樸樢檐檍檠檄檢檣" -- 0x9e
      , "檗蘗檻櫃櫂檸檳檬櫞櫑櫟檪櫚櫪櫻欅蘖櫺欒欖鬱欟欸欷盜欹飮歇歃歉歐歙歔歛歟歡歸歹歿殀殄殃殍殘殕殞殤殪殫殯殲殱殳殷殼毆毋毓毟毬毫毳毯\0麾氈氓气氛氤氣汞汕汢汪沂沍沚沁沛汾汨汳沒沐泄泱泓沽泗泅泝沮沱沾沺泛泯泙泪洟衍洶洫洽洸洙洵洳洒洌浣涓浤浚浹浙涎涕濤涅淹渕渊涵淇淦涸淆淬淞淌淨淒淅淺淙淤淕淪淮渭湮渮渙湲湟渾渣湫渫湶湍渟湃渺湎渤滿渝游溂溪溘滉溷滓溽溯滄溲滔滕溏溥滂溟潁漑灌滬滸滾漿滲漱滯漲滌" -- 0x9f
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xa0
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xa1
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xa2
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xa3
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xa4
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xa5
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xa6
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xa7
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xa8
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xa9
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xaa
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xab
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xac
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xad
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xae
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xaf
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xb0
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xb1
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xb2
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xb3
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xb4
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xb5
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xb6
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xb7
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xb8
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xb9
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xba
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xbb
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xbc
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xbd
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xbe
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xbf
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xc0
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xc1
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xc2
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xc3
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xc4
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xc5
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xc6
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xc7
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xc8
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xc9
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xca
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xcb
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xcc
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xcd
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xce
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xcf
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xd0
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xd1
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xd2
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xd3
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xd4
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xd5
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xd6
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xd7
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xd8
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xd9
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xda
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xdb
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xdc
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xdd
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xde
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xdf
      , "漾漓滷澆潺潸澁澀潯潛濳潭澂潼潘澎澑濂潦澳澣澡澤澹濆澪濟濕濬濔濘濱濮濛瀉瀋濺瀑瀁瀏濾瀛瀚潴瀝瀘瀟瀰瀾瀲灑灣炙炒炯烱炬炸炳炮烟烋烝\0烙焉烽焜焙煥煕熈煦煢煌煖煬熏燻熄熕熨熬燗熹熾燒燉燔燎燠燬燧燵燼燹燿爍爐爛爨爭爬爰爲爻爼爿牀牆牋牘牴牾犂犁犇犒犖犢犧犹犲狃狆狄狎狒狢狠狡狹狷倏猗猊猜猖猝猴猯猩猥猾獎獏默獗獪獨獰獸獵獻獺珈玳珎玻珀珥珮珞璢琅瑯琥珸琲琺瑕琿瑟瑙瑁瑜瑩瑰瑣瑪瑶瑾璋璞璧瓊瓏瓔珱" -- 0xe0
      , "瓠瓣瓧瓩瓮瓲瓰瓱瓸瓷甄甃甅甌甎甍甕甓甞甦甬甼畄畍畊畉畛畆畚畩畤畧畫畭畸當疆疇畴疊疉疂疔疚疝疥疣痂疳痃疵疽疸疼疱痍痊痒痙痣痞痾痿\0痼瘁痰痺痲痳瘋瘍瘉瘟瘧瘠瘡瘢瘤瘴瘰瘻癇癈癆癜癘癡癢癨癩癪癧癬癰癲癶癸發皀皃皈皋皎皖皓皙皚皰皴皸皹皺盂盍盖盒盞盡盥盧盪蘯盻眈眇眄眩眤眞眥眦眛眷眸睇睚睨睫睛睥睿睾睹瞎瞋瞑瞠瞞瞰瞶瞹瞿瞼瞽瞻矇矍矗矚矜矣矮矼砌砒礦砠礪硅碎硴碆硼碚碌碣碵碪碯磑磆磋磔碾碼磅磊磬" -- 0xe1
      , "磧磚磽磴礇礒礑礙礬礫祀祠祗祟祚祕祓祺祿禊禝禧齋禪禮禳禹禺秉秕秧秬秡秣稈稍稘稙稠稟禀稱稻稾稷穃穗穉穡穢穩龝穰穹穽窈窗窕窘窖窩竈窰\0窶竅竄窿邃竇竊竍竏竕竓站竚竝竡竢竦竭竰笂笏笊笆笳笘笙笞笵笨笶筐筺笄筍笋筌筅筵筥筴筧筰筱筬筮箝箘箟箍箜箚箋箒箏筝箙篋篁篌篏箴篆篝篩簑簔篦篥籠簀簇簓篳篷簗簍篶簣簧簪簟簷簫簽籌籃籔籏籀籐籘籟籤籖籥籬籵粃粐粤粭粢粫粡粨粳粲粱粮粹粽糀糅糂糘糒糜糢鬻糯糲糴糶糺紆" -- 0xe2
      , "紂紜紕紊絅絋紮紲紿紵絆絳絖絎絲絨絮絏絣經綉絛綏絽綛綺綮綣綵緇綽綫總綢綯緜綸綟綰緘緝緤緞緻緲緡縅縊縣縡縒縱縟縉縋縢繆繦縻縵縹繃縷\0縲縺繧繝繖繞繙繚繹繪繩繼繻纃緕繽辮繿纈纉續纒纐纓纔纖纎纛纜缸缺罅罌罍罎罐网罕罔罘罟罠罨罩罧罸羂羆羃羈羇羌羔羞羝羚羣羯羲羹羮羶羸譱翅翆翊翕翔翡翦翩翳翹飜耆耄耋耒耘耙耜耡耨耿耻聊聆聒聘聚聟聢聨聳聲聰聶聹聽聿肄肆肅肛肓肚肭冐肬胛胥胙胝胄胚胖脉胯胱脛脩脣脯腋" -- 0xe3
      , "隋腆脾腓腑胼腱腮腥腦腴膃膈膊膀膂膠膕膤膣腟膓膩膰膵膾膸膽臀臂膺臉臍臑臙臘臈臚臟臠臧臺臻臾舁舂舅與舊舍舐舖舩舫舸舳艀艙艘艝艚艟艤\0艢艨艪艫舮艱艷艸艾芍芒芫芟芻芬苡苣苟苒苴苳苺莓范苻苹苞茆苜茉苙茵茴茖茲茱荀茹荐荅茯茫茗茘莅莚莪莟莢莖茣莎莇莊荼莵荳荵莠莉莨菴萓菫菎菽萃菘萋菁菷萇菠菲萍萢萠莽萸蔆菻葭萪萼蕚蒄葷葫蒭葮蒂葩葆萬葯葹萵蓊葢蒹蒿蒟蓙蓍蒻蓚蓐蓁蓆蓖蒡蔡蓿蓴蔗蔘蔬蔟蔕蔔蓼蕀蕣蕘蕈" -- 0xe4
      , "蕁蘂蕋蕕薀薤薈薑薊薨蕭薔薛藪薇薜蕷蕾薐藉薺藏薹藐藕藝藥藜藹蘊蘓蘋藾藺蘆蘢蘚蘰蘿虍乕虔號虧虱蚓蚣蚩蚪蚋蚌蚶蚯蛄蛆蚰蛉蠣蚫蛔蛞蛩蛬\0蛟蛛蛯蜒蜆蜈蜀蜃蛻蜑蜉蜍蛹蜊蜴蜿蜷蜻蜥蜩蜚蝠蝟蝸蝌蝎蝴蝗蝨蝮蝙蝓蝣蝪蠅螢螟螂螯蟋螽蟀蟐雖螫蟄螳蟇蟆螻蟯蟲蟠蠏蠍蟾蟶蟷蠎蟒蠑蠖蠕蠢蠡蠱蠶蠹蠧蠻衄衂衒衙衞衢衫袁衾袞衵衽袵衲袂袗袒袮袙袢袍袤袰袿袱裃裄裔裘裙裝裹褂裼裴裨裲褄褌褊褓襃褞褥褪褫襁襄褻褶褸襌褝襠襞" -- 0xe5
      , "襦襤襭襪襯襴襷襾覃覈覊覓覘覡覩覦覬覯覲覺覽覿觀觚觜觝觧觴觸訃訖訐訌訛訝訥訶詁詛詒詆詈詼詭詬詢誅誂誄誨誡誑誥誦誚誣諄諍諂諚諫諳諧\0諤諱謔諠諢諷諞諛謌謇謚諡謖謐謗謠謳鞫謦謫謾謨譁譌譏譎證譖譛譚譫譟譬譯譴譽讀讌讎讒讓讖讙讚谺豁谿豈豌豎豐豕豢豬豸豺貂貉貅貊貍貎貔豼貘戝貭貪貽貲貳貮貶賈賁賤賣賚賽賺賻贄贅贊贇贏贍贐齎贓賍贔贖赧赭赱赳趁趙跂趾趺跏跚跖跌跛跋跪跫跟跣跼踈踉跿踝踞踐踟蹂踵踰踴蹊" -- 0xe6
      , "蹇蹉蹌蹐蹈蹙蹤蹠踪蹣蹕蹶蹲蹼躁躇躅躄躋躊躓躑躔躙躪躡躬躰軆躱躾軅軈軋軛軣軼軻軫軾輊輅輕輒輙輓輜輟輛輌輦輳輻輹轅轂輾轌轉轆轎轗轜\0轢轣轤辜辟辣辭辯辷迚迥迢迪迯邇迴逅迹迺逑逕逡逍逞逖逋逧逶逵逹迸遏遐遑遒逎遉逾遖遘遞遨遯遶隨遲邂遽邁邀邊邉邏邨邯邱邵郢郤扈郛鄂鄒鄙鄲鄰酊酖酘酣酥酩酳酲醋醉醂醢醫醯醪醵醴醺釀釁釉釋釐釖釟釡釛釼釵釶鈞釿鈔鈬鈕鈑鉞鉗鉅鉉鉤鉈銕鈿鉋鉐銜銖銓銛鉚鋏銹銷鋩錏鋺鍄錮" -- 0xe7
      , "錙錢錚錣錺錵錻鍜鍠鍼鍮鍖鎰鎬鎭鎔鎹鏖鏗鏨鏥鏘鏃鏝鏐鏈鏤鐚鐔鐓鐃鐇鐐鐶鐫鐵鐡鐺鑁鑒鑄鑛鑠鑢鑞鑪鈩鑰鑵鑷鑽鑚鑼鑾钁鑿閂閇閊閔閖閘閙\0閠閨閧閭閼閻閹閾闊濶闃闍闌闕闔闖關闡闥闢阡阨阮阯陂陌陏陋陷陜陞陝陟陦陲陬隍隘隕隗險隧隱隲隰隴隶隸隹雎雋雉雍襍雜霍雕雹霄霆霈霓霎霑霏霖霙霤霪霰霹霽霾靄靆靈靂靉靜靠靤靦靨勒靫靱靹鞅靼鞁靺鞆鞋鞏鞐鞜鞨鞦鞣鞳鞴韃韆韈韋韜韭齏韲竟韶韵頏頌頸頤頡頷頽顆顏顋顫顯顰" -- 0xe8
      , "顱顴顳颪颯颱颶飄飃飆飩飫餃餉餒餔餘餡餝餞餤餠餬餮餽餾饂饉饅饐饋饑饒饌饕馗馘馥馭馮馼駟駛駝駘駑駭駮駱駲駻駸騁騏騅駢騙騫騷驅驂驀驃\0騾驕驍驛驗驟驢驥驤驩驫驪骭骰骼髀髏髑髓體髞髟髢髣髦髯髫髮髴髱髷髻鬆鬘鬚鬟鬢鬣鬥鬧鬨鬩鬪鬮鬯鬲魄魃魏魍魎魑魘魴鮓鮃鮑鮖鮗鮟鮠鮨鮴鯀鯊鮹鯆鯏鯑鯒鯣鯢鯤鯔鯡鰺鯲鯱鯰鰕鰔鰉鰓鰌鰆鰈鰒鰊鰄鰮鰛鰥鰤鰡鰰鱇鰲鱆鰾鱚鱠鱧鱶鱸鳧鳬鳰鴉鴈鳫鴃鴆鴪鴦鶯鴣鴟鵄鴕鴒鵁鴿鴾鵆鵈" -- 0xe9
      , "鵝鵞鵤鵑鵐鵙鵲鶉鶇鶫鵯鵺鶚鶤鶩鶲鷄鷁鶻鶸鶺鷆鷏鷂鷙鷓鷸鷦鷭鷯鷽鸚鸛鸞鹵鹹鹽麁麈麋麌麒麕麑麝麥麩麸麪麭靡黌黎黏黐黔黜點黝黠黥黨黯\0黴黶黷黹黻黼黽鼇鼈皷鼕鼡鼬鼾齊齒齔齣齟齠齡齦齧齬齪齷齲齶龕龜龠堯槇遙瑤凜熙\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xea
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xeb
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xec
      , "纊褜鍈銈蓜俉炻昱棈鋹曻彅丨仡仼伀伃伹佖侒侊侚侔俍偀倢俿倞偆偰偂傔僴僘兊兤冝冾凬刕劜劦勀勛匀匇匤卲厓厲叝﨎咜咊咩哿喆坙坥垬埈埇﨏\0塚增墲夋奓奛奝奣妤妺孖寀甯寘寬尞岦岺峵崧嵓﨑嵂嵭嶸嶹巐弡弴彧德忞恝悅悊惞惕愠惲愑愷愰憘戓抦揵摠撝擎敎昀昕昻昉昮昞昤晥晗晙晴晳暙暠暲暿曺朎朗杦枻桒柀栁桄棏﨓楨﨔榘槢樰橫橆橳橾櫢櫤毖氿汜沆汯泚洄涇浯涖涬淏淸淲淼渹湜渧渼溿澈澵濵瀅瀇瀨炅炫焏焄煜煆煇凞燁燾犱" -- 0xed
      , "犾猤猪獷玽珉珖珣珒琇珵琦琪琩琮瑢璉璟甁畯皂皜皞皛皦益睆劯砡硎硤硺礰礼神祥禔福禛竑竧靖竫箞精絈絜綷綠緖繒罇羡羽茁荢荿菇菶葈蒴蕓蕙\0蕫﨟薰蘒﨡蠇裵訒訷詹誧誾諟諸諶譓譿賰賴贒赶﨣軏﨤逸遧郞都鄕鄧釚釗釞釭釮釤釥鈆鈐鈊鈺鉀鈼鉎鉙鉑鈹鉧銧鉷鉸鋧鋗鋙鋐﨧鋕鋠鋓錥錡鋻﨨錞鋿錝錂鍰鍗鎤鏆鏞鏸鐱鑅鑈閒隆﨩隝隯霳霻靃靍靏靑靕顗顥飯飼餧館馞驎髙髜魵魲鮏鮱鮻鰀鵰鵫鶴鸙黑\0\0ⅰⅱⅲⅳⅴⅵⅶⅷⅸⅹ￢￤＇＂" -- 0xee
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xef
      , "\57344\57345\57346\57347\57348\57349\57350\57351\57352\57353\57354\57355\57356\57357\57358\57359\57360\57361\57362\57363\57364\57365\57366\57367\57368\57369\57370\57371\57372\57373\57374\57375\57376\57377\57378\57379\57380\57381\57382\57383\57384\57385\57386\57387\57388\57389\57390\57391\57392\57393\57394\57395\57396\57397\57398\57399\57400\57401\57402\57403\57404\57405\57406\0\57407\57408\57409\57410\57411\57412\57413\57414\57415\57416\57417\57418\57419\57420\57421\57422\57423\57424\57425\57426\57427\57428\57429\57430\57431\57432\57433\57434\57435\57436\57437\57438\57439\57440\57441\57442\57443\57444\57445\57446\57447\57448\57449\57450\57451\57452\57453\57454\57455\57456\57457\57458\57459\57460\57461\57462\57463\57464\57465\57466\57467\57468\57469\57470\57471\57472\57473\57474\57475\57476\57477\57478\57479\57480\57481\57482\57483\57484\57485\57486\57487\57488\57489\57490\57491\57492\57493\57494\57495\57496\57497\57498\57499\57500\57501\57502\57503\57504\57505\57506\57507\57508\57509\57510\57511\57512\57513\57514\57515\57516\57517\57518\57519\57520\57521\57522\57523\57524\57525\57526\57527\57528\57529\57530\57531" -- 0xf0
      , "\57532\57533\57534\57535\57536\57537\57538\57539\57540\57541\57542\57543\57544\57545\57546\57547\57548\57549\57550\57551\57552\57553\57554\57555\57556\57557\57558\57559\57560\57561\57562\57563\57564\57565\57566\57567\57568\57569\57570\57571\57572\57573\57574\57575\57576\57577\57578\57579\57580\57581\57582\57583\57584\57585\57586\57587\57588\57589\57590\57591\57592\57593\57594\0\57595\57596\57597\57598\57599\57600\57601\57602\57603\57604\57605\57606\57607\57608\57609\57610\57611\57612\57613\57614\57615\57616\57617\57618\57619\57620\57621\57622\57623\57624\57625\57626\57627\57628\57629\57630\57631\57632\57633\57634\57635\57636\57637\57638\57639\57640\57641\57642\57643\57644\57645\57646\57647\57648\57649\57650\57651\57652\57653\57654\57655\57656\57657\57658\57659\57660\57661\57662\57663\57664\57665\57666\57667\57668\57669\57670\57671\57672\57673\57674\57675\57676\57677\57678\57679\57680\57681\57682\57683\57684\57685\57686\57687\57688\57689\57690\57691\57692\57693\57694\57695\57696\57697\57698\57699\57700\57701\57702\57703\57704\57705\57706\57707\57708\57709\57710\57711\57712\57713\57714\57715\57716\57717\57718\57719" -- 0xf1
      , "\57720\57721\57722\57723\57724\57725\57726\57727\57728\57729\57730\57731\57732\57733\57734\57735\57736\57737\57738\57739\57740\57741\57742\57743\57744\57745\57746\57747\57748\57749\57750\57751\57752\57753\57754\57755\57756\57757\57758\57759\57760\57761\57762\57763\57764\57765\57766\57767\57768\57769\57770\57771\57772\57773\57774\57775\57776\57777\57778\57779\57780\57781\57782\0\57783\57784\57785\57786\57787\57788\57789\57790\57791\57792\57793\57794\57795\57796\57797\57798\57799\57800\57801\57802\57803\57804\57805\57806\57807\57808\57809\57810\57811\57812\57813\57814\57815\57816\57817\57818\57819\57820\57821\57822\57823\57824\57825\57826\57827\57828\57829\57830\57831\57832\57833\57834\57835\57836\57837\57838\57839\57840\57841\57842\57843\57844\57845\57846\57847\57848\57849\57850\57851\57852\57853\57854\57855\57856\57857\57858\57859\57860\57861\57862\57863\57864\57865\57866\57867\57868\57869\57870\57871\57872\57873\57874\57875\57876\57877\57878\57879\57880\57881\57882\57883\57884\57885\57886\57887\57888\57889\57890\57891\57892\57893\57894\57895\57896\57897\57898\57899\57900\57901\57902\57903\57904\57905\57906\57907" -- 0xf2
      , "\57908\57909\57910\57911\57912\57913\57914\57915\57916\57917\57918\57919\57920\57921\57922\57923\57924\57925\57926\57927\57928\57929\57930\57931\57932\57933\57934\57935\57936\57937\57938\57939\57940\57941\57942\57943\57944\57945\57946\57947\57948\57949\57950\57951\57952\57953\57954\57955\57956\57957\57958\57959\57960\57961\57962\57963\57964\57965\57966\57967\57968\57969\57970\0\57971\57972\57973\57974\57975\57976\57977\57978\57979\57980\57981\57982\57983\57984\57985\57986\57987\57988\57989\57990\57991\57992\57993\57994\57995\57996\57997\57998\57999\58000\58001\58002\58003\58004\58005\58006\58007\58008\58009\58010\58011\58012\58013\58014\58015\58016\58017\58018\58019\58020\58021\58022\58023\58024\58025\58026\58027\58028\58029\58030\58031\58032\58033\58034\58035\58036\58037\58038\58039\58040\58041\58042\58043\58044\58045\58046\58047\58048\58049\58050\58051\58052\58053\58054\58055\58056\58057\58058\58059\58060\58061\58062\58063\58064\58065\58066\58067\58068\58069\58070\58071\58072\58073\58074\58075\58076\58077\58078\58079\58080\58081\58082\58083\58084\58085\58086\58087\58088\58089\58090\58091\58092\58093\58094\58095" -- 0xf3
      , "\58096\58097\58098\58099\58100\58101\58102\58103\58104\58105\58106\58107\58108\58109\58110\58111\58112\58113\58114\58115\58116\58117\58118\58119\58120\58121\58122\58123\58124\58125\58126\58127\58128\58129\58130\58131\58132\58133\58134\58135\58136\58137\58138\58139\58140\58141\58142\58143\58144\58145\58146\58147\58148\58149\58150\58151\58152\58153\58154\58155\58156\58157\58158\0\58159\58160\58161\58162\58163\58164\58165\58166\58167\58168\58169\58170\58171\58172\58173\58174\58175\58176\58177\58178\58179\58180\58181\58182\58183\58184\58185\58186\58187\58188\58189\58190\58191\58192\58193\58194\58195\58196\58197\58198\58199\58200\58201\58202\58203\58204\58205\58206\58207\58208\58209\58210\58211\58212\58213\58214\58215\58216\58217\58218\58219\58220\58221\58222\58223\58224\58225\58226\58227\58228\58229\58230\58231\58232\58233\58234\58235\58236\58237\58238\58239\58240\58241\58242\58243\58244\58245\58246\58247\58248\58249\58250\58251\58252\58253\58254\58255\58256\58257\58258\58259\58260\58261\58262\58263\58264\58265\58266\58267\58268\58269\58270\58271\58272\58273\58274\58275\58276\58277\58278\58279\58280\58281\58282\58283" -- 0xf4
      , "\58284\58285\58286\58287\58288\58289\58290\58291\58292\58293\58294\58295\58296\58297\58298\58299\58300\58301\58302\58303\58304\58305\58306\58307\58308\58309\58310\58311\58312\58313\58314\58315\58316\58317\58318\58319\58320\58321\58322\58323\58324\58325\58326\58327\58328\58329\58330\58331\58332\58333\58334\58335\58336\58337\58338\58339\58340\58341\58342\58343\58344\58345\58346\0\58347\58348\58349\58350\58351\58352\58353\58354\58355\58356\58357\58358\58359\58360\58361\58362\58363\58364\58365\58366\58367\58368\58369\58370\58371\58372\58373\58374\58375\58376\58377\58378\58379\58380\58381\58382\58383\58384\58385\58386\58387\58388\58389\58390\58391\58392\58393\58394\58395\58396\58397\58398\58399\58400\58401\58402\58403\58404\58405\58406\58407\58408\58409\58410\58411\58412\58413\58414\58415\58416\58417\58418\58419\58420\58421\58422\58423\58424\58425\58426\58427\58428\58429\58430\58431\58432\58433\58434\58435\58436\58437\58438\58439\58440\58441\58442\58443\58444\58445\58446\58447\58448\58449\58450\58451\58452\58453\58454\58455\58456\58457\58458\58459\58460\58461\58462\58463\58464\58465\58466\58467\58468\58469\58470\58471" -- 0xf5
      , "\58472\58473\58474\58475\58476\58477\58478\58479\58480\58481\58482\58483\58484\58485\58486\58487\58488\58489\58490\58491\58492\58493\58494\58495\58496\58497\58498\58499\58500\58501\58502\58503\58504\58505\58506\58507\58508\58509\58510\58511\58512\58513\58514\58515\58516\58517\58518\58519\58520\58521\58522\58523\58524\58525\58526\58527\58528\58529\58530\58531\58532\58533\58534\0\58535\58536\58537\58538\58539\58540\58541\58542\58543\58544\58545\58546\58547\58548\58549\58550\58551\58552\58553\58554\58555\58556\58557\58558\58559\58560\58561\58562\58563\58564\58565\58566\58567\58568\58569\58570\58571\58572\58573\58574\58575\58576\58577\58578\58579\58580\58581\58582\58583\58584\58585\58586\58587\58588\58589\58590\58591\58592\58593\58594\58595\58596\58597\58598\58599\58600\58601\58602\58603\58604\58605\58606\58607\58608\58609\58610\58611\58612\58613\58614\58615\58616\58617\58618\58619\58620\58621\58622\58623\58624\58625\58626\58627\58628\58629\58630\58631\58632\58633\58634\58635\58636\58637\58638\58639\58640\58641\58642\58643\58644\58645\58646\58647\58648\58649\58650\58651\58652\58653\58654\58655\58656\58657\58658\58659" -- 0xf6
      , "\58660\58661\58662\58663\58664\58665\58666\58667\58668\58669\58670\58671\58672\58673\58674\58675\58676\58677\58678\58679\58680\58681\58682\58683\58684\58685\58686\58687\58688\58689\58690\58691\58692\58693\58694\58695\58696\58697\58698\58699\58700\58701\58702\58703\58704\58705\58706\58707\58708\58709\58710\58711\58712\58713\58714\58715\58716\58717\58718\58719\58720\58721\58722\0\58723\58724\58725\58726\58727\58728\58729\58730\58731\58732\58733\58734\58735\58736\58737\58738\58739\58740\58741\58742\58743\58744\58745\58746\58747\58748\58749\58750\58751\58752\58753\58754\58755\58756\58757\58758\58759\58760\58761\58762\58763\58764\58765\58766\58767\58768\58769\58770\58771\58772\58773\58774\58775\58776\58777\58778\58779\58780\58781\58782\58783\58784\58785\58786\58787\58788\58789\58790\58791\58792\58793\58794\58795\58796\58797\58798\58799\58800\58801\58802\58803\58804\58805\58806\58807\58808\58809\58810\58811\58812\58813\58814\58815\58816\58817\58818\58819\58820\58821\58822\58823\58824\58825\58826\58827\58828\58829\58830\58831\58832\58833\58834\58835\58836\58837\58838\58839\58840\58841\58842\58843\58844\58845\58846\58847" -- 0xf7
      , "\58848\58849\58850\58851\58852\58853\58854\58855\58856\58857\58858\58859\58860\58861\58862\58863\58864\58865\58866\58867\58868\58869\58870\58871\58872\58873\58874\58875\58876\58877\58878\58879\58880\58881\58882\58883\58884\58885\58886\58887\58888\58889\58890\58891\58892\58893\58894\58895\58896\58897\58898\58899\58900\58901\58902\58903\58904\58905\58906\58907\58908\58909\58910\0\58911\58912\58913\58914\58915\58916\58917\58918\58919\58920\58921\58922\58923\58924\58925\58926\58927\58928\58929\58930\58931\58932\58933\58934\58935\58936\58937\58938\58939\58940\58941\58942\58943\58944\58945\58946\58947\58948\58949\58950\58951\58952\58953\58954\58955\58956\58957\58958\58959\58960\58961\58962\58963\58964\58965\58966\58967\58968\58969\58970\58971\58972\58973\58974\58975\58976\58977\58978\58979\58980\58981\58982\58983\58984\58985\58986\58987\58988\58989\58990\58991\58992\58993\58994\58995\58996\58997\58998\58999\59000\59001\59002\59003\59004\59005\59006\59007\59008\59009\59010\59011\59012\59013\59014\59015\59016\59017\59018\59019\59020\59021\59022\59023\59024\59025\59026\59027\59028\59029\59030\59031\59032\59033\59034\59035" -- 0xf8
      , "\59036\59037\59038\59039\59040\59041\59042\59043\59044\59045\59046\59047\59048\59049\59050\59051\59052\59053\59054\59055\59056\59057\59058\59059\59060\59061\59062\59063\59064\59065\59066\59067\59068\59069\59070\59071\59072\59073\59074\59075\59076\59077\59078\59079\59080\59081\59082\59083\59084\59085\59086\59087\59088\59089\59090\59091\59092\59093\59094\59095\59096\59097\59098\0\59099\59100\59101\59102\59103\59104\59105\59106\59107\59108\59109\59110\59111\59112\59113\59114\59115\59116\59117\59118\59119\59120\59121\59122\59123\59124\59125\59126\59127\59128\59129\59130\59131\59132\59133\59134\59135\59136\59137\59138\59139\59140\59141\59142\59143\59144\59145\59146\59147\59148\59149\59150\59151\59152\59153\59154\59155\59156\59157\59158\59159\59160\59161\59162\59163\59164\59165\59166\59167\59168\59169\59170\59171\59172\59173\59174\59175\59176\59177\59178\59179\59180\59181\59182\59183\59184\59185\59186\59187\59188\59189\59190\59191\59192\59193\59194\59195\59196\59197\59198\59199\59200\59201\59202\59203\59204\59205\59206\59207\59208\59209\59210\59211\59212\59213\59214\59215\59216\59217\59218\59219\59220\59221\59222\59223" -- 0xf9
      , "ⅰⅱⅲⅳⅴⅵⅶⅷⅸⅹⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩ￢￤＇＂㈱№℡∵纊褜鍈銈蓜俉炻昱棈鋹曻彅丨仡仼伀伃伹佖侒侊侚侔俍偀倢俿倞偆偰偂傔僴僘兊\0兤冝冾凬刕劜劦勀勛匀匇匤卲厓厲叝﨎咜咊咩哿喆坙坥垬埈埇﨏塚增墲夋奓奛奝奣妤妺孖寀甯寘寬尞岦岺峵崧嵓﨑嵂嵭嶸嶹巐弡弴彧德忞恝悅悊惞惕愠惲愑愷愰憘戓抦揵摠撝擎敎昀昕昻昉昮昞昤晥晗晙晴晳暙暠暲暿曺朎朗杦枻桒柀栁桄棏﨓楨﨔榘槢樰橫橆橳橾櫢櫤毖氿汜沆汯泚洄涇浯" -- 0xfa
      , "涖涬淏淸淲淼渹湜渧渼溿澈澵濵瀅瀇瀨炅炫焏焄煜煆煇凞燁燾犱犾猤猪獷玽珉珖珣珒琇珵琦琪琩琮瑢璉璟甁畯皂皜皞皛皦益睆劯砡硎硤硺礰礼神\0祥禔福禛竑竧靖竫箞精絈絜綷綠緖繒罇羡羽茁荢荿菇菶葈蒴蕓蕙蕫﨟薰蘒﨡蠇裵訒訷詹誧誾諟諸諶譓譿賰賴贒赶﨣軏﨤逸遧郞都鄕鄧釚釗釞釭釮釤釥鈆鈐鈊鈺鉀鈼鉎鉙鉑鈹鉧銧鉷鉸鋧鋗鋙鋐﨧鋕鋠鋓錥錡鋻﨨錞鋿錝錂鍰鍗鎤鏆鏞鏸鐱鑅鑈閒隆﨩隝隯霳霻靃靍靏靑靕顗顥飯飼餧館馞驎髙" -- 0xfb
      , "髜魵魲鮏鮱鮻鰀鵰鵫鶴鸙黑\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xfc
      ]
  }

-- | Simplified Chinese (GBK).  0 single-byte and 21791 double-byte mappings.
cp936Table :: Codepage
cp936Table = Codepage
  { cpName = "cp936"
  , cpLeadLo = 0x81
  , cpLeadHi = 0xfe
  , cpTrailLo = 0x40
  , cpTrailHi = 0xfe
  , cpSingle = U.listArray (0, 127) "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0"
  , cpDouble = U.listArray (0, 24065) $ concat
      [ "丂丄丅丆丏丒丗丟丠両丣並丩丮丯丱丳丵丷丼乀乁乂乄乆乊乑乕乗乚乛乢乣乤乥乧乨乪乫乬乭乮乯乲乴乵乶乷乸乹乺乻乼乽乿亀亁亂亃亄亅亇亊\0亐亖亗亙亜亝亞亣亪亯亰亱亴亶亷亸亹亼亽亾仈仌仏仐仒仚仛仜仠仢仦仧仩仭仮仯仱仴仸仹仺仼仾伀伂伃伄伅伆伇伈伋伌伒伓伔伕伖伜伝伡伣伨伩伬伭伮伱伳伵伷伹伻伾伿佀佁佂佄佅佇佈佉佊佋佌佒佔佖佡佢佦佨佪佫佭佮佱佲併佷佸佹佺佽侀侁侂侅來侇侊侌侎侐侒侓侕侖侘侙侚侜侞侟価侢" -- 0x81
      , "侤侫侭侰侱侲侳侴侶侷侸侹侺侻侼侽侾俀俁係俆俇俈俉俋俌俍俒俓俔俕俖俙俛俠俢俤俥俧俫俬俰俲俴俵俶俷俹俻俼俽俿倀倁倂倃倄倅倆倇倈倉倊\0個倎倐們倓倕倖倗倛倝倞倠倢倣値倧倫倯倰倱倲倳倴倵倶倷倸倹倻倽倿偀偁偂偄偅偆偉偊偋偍偐偑偒偓偔偖偗偘偙偛偝偞偟偠偡偢偣偤偦偧偨偩偪偫偭偮偯偰偱偲偳側偵偸偹偺偼偽傁傂傃傄傆傇傉傊傋傌傎傏傐傑傒傓傔傕傖傗傘備傚傛傜傝傞傟傠傡傢傤傦傪傫傭傮傯傰傱傳傴債傶傷傸傹傼" -- 0x82
      , "傽傾傿僀僁僂僃僄僅僆僇僈僉僊僋僌働僎僐僑僒僓僔僕僗僘僙僛僜僝僞僟僠僡僢僣僤僥僨僩僪僫僯僰僱僲僴僶僷僸價僺僼僽僾僿儀儁儂儃億儅儈\0儉儊儌儍儎儏儐儑儓儔儕儖儗儘儙儚儛儜儝儞償儠儢儣儤儥儦儧儨儩優儫儬儭儮儯儰儱儲儳儴儵儶儷儸儹儺儻儼儽儾兂兇兊兌兎兏児兒兓兗兘兙兛兝兞兟兠兡兣兤兦內兩兪兯兲兺兾兿冃冄円冇冊冋冎冏冐冑冓冔冘冚冝冞冟冡冣冦冧冨冩冪冭冮冴冸冹冺冾冿凁凂凃凅凈凊凍凎凐凒凓凔凕凖凗" -- 0x83
      , "凘凙凚凜凞凟凢凣凥処凧凨凩凪凬凮凱凲凴凷凾刄刅刉刋刌刏刐刓刔刕刜刞刟刡刢刣別刦刧刪刬刯刱刲刴刵刼刾剄剅剆則剈剉剋剎剏剒剓剕剗剘\0剙剚剛剝剟剠剢剣剤剦剨剫剬剭剮剰剱剳剴創剶剷剸剹剺剻剼剾劀劃劄劅劆劇劉劊劋劌劍劎劏劑劒劔劕劖劗劘劙劚劜劤劥劦劧劮劯劰労劵劶劷劸効劺劻劼劽勀勁勂勄勅勆勈勊勌勍勎勏勑勓勔動勗務勚勛勜勝勞勠勡勢勣勥勦勧勨勩勪勫勬勭勮勯勱勲勳勴勵勶勷勸勻勼勽匁匂匃匄匇匉匊匋匌匎" -- 0x84
      , "匑匒匓匔匘匛匜匞匟匢匤匥匧匨匩匫匬匭匯匰匱匲匳匴匵匶匷匸匼匽區卂卄卆卋卌卍卐協単卙卛卝卥卨卪卬卭卲卶卹卻卼卽卾厀厁厃厇厈厊厎厏\0厐厑厒厓厔厖厗厙厛厜厞厠厡厤厧厪厫厬厭厯厰厱厲厳厴厵厷厸厹厺厼厽厾叀參叄叅叆叇収叏叐叒叓叕叚叜叝叞叡叢叧叴叺叾叿吀吂吅吇吋吔吘吙吚吜吢吤吥吪吰吳吶吷吺吽吿呁呂呄呅呇呉呌呍呎呏呑呚呝呞呟呠呡呣呥呧呩呪呫呬呭呮呯呰呴呹呺呾呿咁咃咅咇咈咉咊咍咑咓咗咘咜咞咟咠咡" -- 0x85
      , "咢咥咮咰咲咵咶咷咹咺咼咾哃哅哊哋哖哘哛哠員哢哣哤哫哬哯哰哱哴哵哶哷哸哹哻哾唀唂唃唄唅唈唊唋唌唍唎唒唓唕唖唗唘唙唚唜唝唞唟唡唥唦\0唨唩唫唭唲唴唵唶唸唹唺唻唽啀啂啅啇啈啋啌啍啎問啑啒啓啔啗啘啙啚啛啝啞啟啠啢啣啨啩啫啯啰啱啲啳啴啹啺啽啿喅喆喌喍喎喐喒喓喕喖喗喚喛喞喠喡喢喣喤喥喦喨喩喪喫喬喭單喯喰喲喴営喸喺喼喿嗀嗁嗂嗃嗆嗇嗈嗊嗋嗎嗏嗐嗕嗗嗘嗙嗚嗛嗞嗠嗢嗧嗩嗭嗮嗰嗱嗴嗶嗸嗹嗺嗻嗼嗿嘂嘃嘄嘅" -- 0x86
      , "嘆嘇嘊嘋嘍嘐嘑嘒嘓嘔嘕嘖嘗嘙嘚嘜嘝嘠嘡嘢嘥嘦嘨嘩嘪嘫嘮嘯嘰嘳嘵嘷嘸嘺嘼嘽嘾噀噁噂噃噄噅噆噇噈噉噊噋噏噐噑噒噓噕噖噚噛噝噞噟噠噡\0噣噥噦噧噭噮噯噰噲噳噴噵噷噸噹噺噽噾噿嚀嚁嚂嚃嚄嚇嚈嚉嚊嚋嚌嚍嚐嚑嚒嚔嚕嚖嚗嚘嚙嚚嚛嚜嚝嚞嚟嚠嚡嚢嚤嚥嚦嚧嚨嚩嚪嚫嚬嚭嚮嚰嚱嚲嚳嚴嚵嚶嚸嚹嚺嚻嚽嚾嚿囀囁囂囃囄囅囆囇囈囉囋囌囍囎囏囐囑囒囓囕囖囘囙囜団囥囦囧囨囩囪囬囮囯囲図囶囷囸囻囼圀圁圂圅圇國圌圍圎圏圐圑" -- 0x87
      , "園圓圔圕圖圗團圙圚圛圝圞圠圡圢圤圥圦圧圫圱圲圴圵圶圷圸圼圽圿坁坃坄坅坆坈坉坋坒坓坔坕坖坘坙坢坣坥坧坬坮坰坱坲坴坵坸坹坺坽坾坿垀\0垁垇垈垉垊垍垎垏垐垑垔垕垖垗垘垙垚垜垝垞垟垥垨垪垬垯垰垱垳垵垶垷垹垺垻垼垽垾垿埀埁埄埅埆埇埈埉埊埌埍埐埑埓埖埗埛埜埞埡埢埣埥埦埧埨埩埪埫埬埮埰埱埲埳埵埶執埻埼埾埿堁堃堄堅堈堉堊堌堎堏堐堒堓堔堖堗堘堚堛堜堝堟堢堣堥堦堧堨堩堫堬堭堮堯報堲堳場堶堷堸堹堺堻堼堽" -- 0x88
      , "堾堿塀塁塂塃塅塆塇塈塉塊塋塎塏塐塒塓塕塖塗塙塚塛塜塝塟塠塡塢塣塤塦塧塨塩塪塭塮塯塰塱塲塳塴塵塶塷塸塹塺塻塼塽塿墂墄墆墇墈墊墋墌\0墍墎墏墐墑墔墕墖増墘墛墜墝墠墡墢墣墤墥墦墧墪墫墬墭墮墯墰墱墲墳墴墵墶墷墸墹墺墻墽墾墿壀壂壃壄壆壇壈壉壊壋壌壍壎壏壐壒壓壔壖壗壘壙壚壛壜壝壞壟壠壡壢壣壥壦壧壨壩壪壭壯壱売壴壵壷壸壺壻壼壽壾壿夀夁夃夅夆夈変夊夋夌夎夐夑夒夓夗夘夛夝夞夠夡夢夣夦夨夬夰夲夳夵夶夻" -- 0x89
      , "夽夾夿奀奃奅奆奊奌奍奐奒奓奙奛奜奝奞奟奡奣奤奦奧奨奩奪奫奬奭奮奯奰奱奲奵奷奺奻奼奾奿妀妅妉妋妌妎妏妐妑妔妕妘妚妛妜妝妟妠妡妢妦\0妧妬妭妰妱妳妴妵妶妷妸妺妼妽妿姀姁姂姃姄姅姇姈姉姌姍姎姏姕姖姙姛姞姟姠姡姢姤姦姧姩姪姫姭姮姯姰姱姲姳姴姵姶姷姸姺姼姽姾娀娂娊娋娍娎娏娐娒娔娕娖娗娙娚娛娝娞娡娢娤娦娧娨娪娫娬娭娮娯娰娳娵娷娸娹娺娻娽娾娿婁婂婃婄婅婇婈婋婌婍婎婏婐婑婒婓婔婖婗婘婙婛婜婝婞婟婠" -- 0x8a
      , "婡婣婤婥婦婨婩婫婬婭婮婯婰婱婲婳婸婹婻婼婽婾媀媁媂媃媄媅媆媇媈媉媊媋媌媍媎媏媐媑媓媔媕媖媗媘媙媜媝媞媟媠媡媢媣媤媥媦媧媨媩媫媬\0媭媮媯媰媱媴媶媷媹媺媻媼媽媿嫀嫃嫄嫅嫆嫇嫈嫊嫋嫍嫎嫏嫐嫑嫓嫕嫗嫙嫚嫛嫝嫞嫟嫢嫤嫥嫧嫨嫪嫬嫭嫮嫯嫰嫲嫳嫴嫵嫶嫷嫸嫹嫺嫻嫼嫽嫾嫿嬀嬁嬂嬃嬄嬅嬆嬇嬈嬊嬋嬌嬍嬎嬏嬐嬑嬒嬓嬔嬕嬘嬙嬚嬛嬜嬝嬞嬟嬠嬡嬢嬣嬤嬥嬦嬧嬨嬩嬪嬫嬬嬭嬮嬯嬰嬱嬳嬵嬶嬸嬹嬺嬻嬼嬽嬾嬿孁孂孃孄孅孆孇" -- 0x8b
      , "孈孉孊孋孌孍孎孏孒孖孞孠孡孧孨孫孭孮孯孲孴孶孷學孹孻孼孾孿宂宆宊宍宎宐宑宒宔宖実宧宨宩宬宭宮宯宱宲宷宺宻宼寀寁寃寈寉寊寋寍寎寏\0寑寔寕寖寗寘寙寚寛寜寠寢寣實寧審寪寫寬寭寯寱寲寳寴寵寶寷寽対尀専尃尅將專尋尌對導尐尒尓尗尙尛尞尟尠尡尣尦尨尩尪尫尭尮尯尰尲尳尵尶尷屃屄屆屇屌屍屒屓屔屖屗屘屚屛屜屝屟屢層屧屨屩屪屫屬屭屰屲屳屴屵屶屷屸屻屼屽屾岀岃岄岅岆岇岉岊岋岎岏岒岓岕岝岞岟岠岡岤岥岦岧岨" -- 0x8c
      , "岪岮岯岰岲岴岶岹岺岻岼岾峀峂峃峅峆峇峈峉峊峌峍峎峏峐峑峓峔峕峖峗峘峚峛峜峝峞峟峠峢峣峧峩峫峬峮峯峱峲峳峴峵島峷峸峹峺峼峽峾峿崀\0崁崄崅崈崉崊崋崌崍崏崐崑崒崓崕崗崘崙崚崜崝崟崠崡崢崣崥崨崪崫崬崯崰崱崲崳崵崶崷崸崹崺崻崼崿嵀嵁嵂嵃嵄嵅嵆嵈嵉嵍嵎嵏嵐嵑嵒嵓嵔嵕嵖嵗嵙嵚嵜嵞嵟嵠嵡嵢嵣嵤嵥嵦嵧嵨嵪嵭嵮嵰嵱嵲嵳嵵嵶嵷嵸嵹嵺嵻嵼嵽嵾嵿嶀嶁嶃嶄嶅嶆嶇嶈嶉嶊嶋嶌嶍嶎嶏嶐嶑嶒嶓嶔嶕嶖嶗嶘嶚嶛嶜嶞嶟嶠" -- 0x8d
      , "嶡嶢嶣嶤嶥嶦嶧嶨嶩嶪嶫嶬嶭嶮嶯嶰嶱嶲嶳嶴嶵嶶嶸嶹嶺嶻嶼嶽嶾嶿巀巁巂巃巄巆巇巈巉巊巋巌巎巏巐巑巒巓巔巕巖巗巘巙巚巜巟巠巣巤巪巬巭\0巰巵巶巸巹巺巻巼巿帀帄帇帉帊帋帍帎帒帓帗帞帟帠帡帢帣帤帥帨帩帪師帬帯帰帲帳帴帵帶帹帺帾帿幀幁幃幆幇幈幉幊幋幍幎幏幐幑幒幓幖幗幘幙幚幜幝幟幠幣幤幥幦幧幨幩幪幫幬幭幮幯幰幱幵幷幹幾庁庂広庅庈庉庌庍庎庒庘庛庝庡庢庣庤庨庩庪庫庬庮庯庰庱庲庴庺庻庼庽庿廀廁廂廃廄廅" -- 0x8e
      , "廆廇廈廋廌廍廎廏廐廔廕廗廘廙廚廜廝廞廟廠廡廢廣廤廥廦廧廩廫廬廭廮廯廰廱廲廳廵廸廹廻廼廽弅弆弇弉弌弍弎弐弒弔弖弙弚弜弝弞弡弢弣弤\0弨弫弬弮弰弲弳弴張弶強弸弻弽弾弿彁彂彃彄彅彆彇彈彉彊彋彌彍彎彏彑彔彙彚彛彜彞彟彠彣彥彧彨彫彮彯彲彴彵彶彸彺彽彾彿徃徆徍徎徏徑従徔徖徚徛徝從徟徠徢徣徤徥徦徧復徫徬徯徰徱徲徳徴徶徸徹徺徻徾徿忀忁忂忇忈忊忋忎忓忔忕忚忛応忞忟忢忣忥忦忨忩忬忯忰忲忳忴忶忷忹忺忼怇" -- 0x8f
      , "怈怉怋怌怐怑怓怗怘怚怞怟怢怣怤怬怭怮怰怱怲怳怴怶怷怸怹怺怽怾恀恄恅恆恇恈恉恊恌恎恏恑恓恔恖恗恘恛恜恞恟恠恡恥恦恮恱恲恴恵恷恾悀\0悁悂悅悆悇悈悊悋悎悏悐悑悓悕悗悘悙悜悞悡悢悤悥悧悩悪悮悰悳悵悶悷悹悺悽悾悿惀惁惂惃惄惇惈惉惌惍惎惏惐惒惓惔惖惗惙惛惞惡惢惣惤惥惪惱惲惵惷惸惻惼惽惾惿愂愃愄愅愇愊愋愌愐愑愒愓愔愖愗愘愙愛愜愝愞愡愢愥愨愩愪愬愭愮愯愰愱愲愳愴愵愶愷愸愹愺愻愼愽愾慀慁慂慃慄慅慆" -- 0x90
      , "慇慉態慍慏慐慒慓慔慖慗慘慙慚慛慜慞慟慠慡慣慤慥慦慩慪慫慬慭慮慯慱慲慳慴慶慸慹慺慻慼慽慾慿憀憁憂憃憄憅憆憇憈憉憊憌憍憏憐憑憒憓憕\0憖憗憘憙憚憛憜憞憟憠憡憢憣憤憥憦憪憫憭憮憯憰憱憲憳憴憵憶憸憹憺憻憼憽憿懀懁懃懄懅懆懇應懌懍懎懏懐懓懕懖懗懘懙懚懛懜懝懞懟懠懡懢懣懤懥懧懨懩懪懫懬懭懮懯懰懱懲懳懴懶懷懸懹懺懻懼懽懾戀戁戂戃戄戅戇戉戓戔戙戜戝戞戠戣戦戧戨戩戫戭戯戰戱戲戵戶戸戹戺戻戼扂扄扅扆扊" -- 0x91
      , "扏扐払扖扗扙扚扜扝扞扟扠扡扢扤扥扨扱扲扴扵扷扸扺扻扽抁抂抃抅抆抇抈抋抌抍抎抏抐抔抙抜抝択抣抦抧抩抪抭抮抯抰抲抳抴抶抷抸抺抾拀拁\0拃拋拏拑拕拝拞拠拡拤拪拫拰拲拵拸拹拺拻挀挃挄挅挆挊挋挌挍挏挐挒挓挔挕挗挘挙挜挦挧挩挬挭挮挰挱挳挴挵挶挷挸挻挼挾挿捀捁捄捇捈捊捑捒捓捔捖捗捘捙捚捛捜捝捠捤捥捦捨捪捫捬捯捰捲捳捴捵捸捹捼捽捾捿掁掃掄掅掆掋掍掑掓掔掕掗掙掚掛掜掝掞掟採掤掦掫掯掱掲掵掶掹掻掽掿揀" -- 0x92
      , "揁揂揃揅揇揈揊揋揌揑揓揔揕揗揘揙揚換揜揝揟揢揤揥揦揧揨揫揬揮揯揰揱揳揵揷揹揺揻揼揾搃搄搆搇搈搉搊損搎搑搒搕搖搗搘搙搚搝搟搢搣搤\0搥搧搨搩搫搮搯搰搱搲搳搵搶搷搸搹搻搼搾摀摂摃摉摋摌摍摎摏摐摑摓摕摖摗摙摚摛摜摝摟摠摡摢摣摤摥摦摨摪摫摬摮摯摰摱摲摳摴摵摶摷摻摼摽摾摿撀撁撃撆撈撉撊撋撌撍撎撏撐撓撔撗撘撚撛撜撝撟撠撡撢撣撥撦撧撨撪撫撯撱撲撳撴撶撹撻撽撾撿擁擃擄擆擇擈擉擊擋擌擏擑擓擔擕擖擙據" -- 0x93
      , "擛擜擝擟擠擡擣擥擧擨擩擪擫擬擭擮擯擰擱擲擳擴擵擶擷擸擹擺擻擼擽擾擿攁攂攃攄攅攆攇攈攊攋攌攍攎攏攐攑攓攔攕攖攗攙攚攛攜攝攞攟攠攡\0攢攣攤攦攧攨攩攪攬攭攰攱攲攳攷攺攼攽敀敁敂敃敄敆敇敊敋敍敎敐敒敓敔敗敘敚敜敟敠敡敤敥敧敨敩敪敭敮敯敱敳敵敶數敹敺敻敼敽敾敿斀斁斂斃斄斅斆斈斉斊斍斎斏斒斔斕斖斘斚斝斞斠斢斣斦斨斪斬斮斱斲斳斴斵斶斷斸斺斻斾斿旀旂旇旈旉旊旍旐旑旓旔旕旘旙旚旛旜旝旞旟旡旣旤旪旫" -- 0x94
      , "旲旳旴旵旸旹旻旼旽旾旿昁昄昅昇昈昉昋昍昐昑昒昖昗昘昚昛昜昞昡昢昣昤昦昩昪昫昬昮昰昲昳昷昸昹昺昻昽昿晀時晄晅晆晇晈晉晊晍晎晐晑晘\0晙晛晜晝晞晠晢晣晥晧晩晪晫晬晭晱晲晳晵晸晹晻晼晽晿暀暁暃暅暆暈暉暊暋暍暎暏暐暒暓暔暕暘暙暚暛暜暞暟暠暡暢暣暤暥暦暩暪暫暬暭暯暰暱暲暳暵暶暷暸暺暻暼暽暿曀曁曂曃曄曅曆曇曈曉曊曋曌曍曎曏曐曑曒曓曔曕曖曗曘曚曞曟曠曡曢曣曤曥曧曨曪曫曬曭曮曯曱曵曶書曺曻曽朁朂會" -- 0x95
      , "朄朅朆朇朌朎朏朑朒朓朖朘朙朚朜朞朠朡朢朣朤朥朧朩朮朰朲朳朶朷朸朹朻朼朾朿杁杄杅杇杊杋杍杒杔杕杗杘杙杚杛杝杢杣杤杦杧杫杬杮東杴杶\0杸杹杺杻杽枀枂枃枅枆枈枊枌枍枎枏枑枒枓枔枖枙枛枟枠枡枤枦枩枬枮枱枲枴枹枺枻枼枽枾枿柀柂柅柆柇柈柉柊柋柌柍柎柕柖柗柛柟柡柣柤柦柧柨柪柫柭柮柲柵柶柷柸柹柺査柼柾栁栂栃栄栆栍栐栒栔栕栘栙栚栛栜栞栟栠栢栣栤栥栦栧栨栫栬栭栮栯栰栱栴栵栶栺栻栿桇桋桍桏桒桖桗桘桙桚桛" -- 0x96
      , "桜桝桞桟桪桬桭桮桯桰桱桲桳桵桸桹桺桻桼桽桾桿梀梂梄梇梈梉梊梋梌梍梎梐梑梒梔梕梖梘梙梚梛梜條梞梟梠梡梣梤梥梩梪梫梬梮梱梲梴梶梷梸\0梹梺梻梼梽梾梿棁棃棄棅棆棇棈棊棌棎棏棐棑棓棔棖棗棙棛棜棝棞棟棡棢棤棥棦棧棨棩棪棫棬棭棯棲棳棴棶棷棸棻棽棾棿椀椂椃椄椆椇椈椉椊椌椏椑椓椔椕椖椗椘椙椚椛検椝椞椡椢椣椥椦椧椨椩椪椫椬椮椯椱椲椳椵椶椷椸椺椻椼椾楀楁楃楄楅楆楇楈楉楊楋楌楍楎楏楐楑楒楓楕楖楘楙楛楜楟" -- 0x97
      , "楡楢楤楥楧楨楩楪楬業楯楰楲楳楴極楶楺楻楽楾楿榁榃榅榊榋榌榎榏榐榑榒榓榖榗榙榚榝榞榟榠榡榢榣榤榥榦榩榪榬榮榯榰榲榳榵榶榸榹榺榼榽\0榾榿槀槂槃槄槅槆槇槈槉構槍槏槑槒槓槕槖槗様槙槚槜槝槞槡槢槣槤槥槦槧槨槩槪槫槬槮槯槰槱槳槴槵槶槷槸槹槺槻槼槾樀樁樂樃樄樅樆樇樈樉樋樌樍樎樏樐樑樒樓樔樕樖標樚樛樜樝樞樠樢樣樤樥樦樧権樫樬樭樮樰樲樳樴樶樷樸樹樺樻樼樿橀橁橂橃橅橆橈橉橊橋橌橍橎橏橑橒橓橔橕橖橗橚" -- 0x98
      , "橜橝橞機橠橢橣橤橦橧橨橩橪橫橬橭橮橯橰橲橳橴橵橶橷橸橺橻橽橾橿檁檂檃檅檆檇檈檉檊檋檌檍檏檒檓檔檕檖檘檙檚檛檜檝檞檟檡檢檣檤檥檦\0檧檨檪檭檮檯檰檱檲檳檴檵檶檷檸檹檺檻檼檽檾檿櫀櫁櫂櫃櫄櫅櫆櫇櫈櫉櫊櫋櫌櫍櫎櫏櫐櫑櫒櫓櫔櫕櫖櫗櫘櫙櫚櫛櫜櫝櫞櫟櫠櫡櫢櫣櫤櫥櫦櫧櫨櫩櫪櫫櫬櫭櫮櫯櫰櫱櫲櫳櫴櫵櫶櫷櫸櫹櫺櫻櫼櫽櫾櫿欀欁欂欃欄欅欆欇欈欉權欋欌欍欎欏欐欑欒欓欔欕欖欗欘欙欚欛欜欝欞欟欥欦欨欩欪欫欬欭欮" -- 0x99
      , "欯欰欱欳欴欵欶欸欻欼欽欿歀歁歂歄歅歈歊歋歍歎歏歐歑歒歓歔歕歖歗歘歚歛歜歝歞歟歠歡歨歩歫歬歭歮歯歰歱歲歳歴歵歶歷歸歺歽歾歿殀殅殈\0殌殎殏殐殑殔殕殗殘殙殜殝殞殟殠殢殣殤殥殦殧殨殩殫殬殭殮殯殰殱殲殶殸殹殺殻殼殽殾毀毃毄毆毇毈毉毊毌毎毐毑毘毚毜毝毞毟毠毢毣毤毥毦毧毨毩毬毭毮毰毱毲毴毶毷毸毺毻毼毾毿氀氁氂氃氄氈氉氊氋氌氎氒気氜氝氞氠氣氥氫氬氭氱氳氶氷氹氺氻氼氾氿汃汄汅汈汋汌汍汎汏汑汒汓汖汘" -- 0x9a
      , "汙汚汢汣汥汦汧汫汬汭汮汯汱汳汵汷汸決汻汼汿沀沄沇沊沋沍沎沑沒沕沖沗沘沚沜沝沞沠沢沨沬沯沰沴沵沶沷沺泀況泂泃泆泇泈泋泍泎泏泑泒泘\0泙泚泜泝泟泤泦泧泩泬泭泲泴泹泿洀洂洃洅洆洈洉洊洍洏洐洑洓洔洕洖洘洜洝洟洠洡洢洣洤洦洨洩洬洭洯洰洴洶洷洸洺洿浀浂浄浉浌浐浕浖浗浘浛浝浟浡浢浤浥浧浨浫浬浭浰浱浲浳浵浶浹浺浻浽浾浿涀涁涃涄涆涇涊涋涍涏涐涒涖涗涘涙涚涜涢涥涬涭涰涱涳涴涶涷涹涺涻涼涽涾淁淂淃淈淉淊" -- 0x9b
      , "淍淎淏淐淒淓淔淕淗淚淛淜淟淢淣淥淧淨淩淪淭淯淰淲淴淵淶淸淺淽淾淿渀渁渂渃渄渆渇済渉渋渏渒渓渕渘渙減渜渞渟渢渦渧渨渪測渮渰渱渳渵\0渶渷渹渻渼渽渾渿湀湁湂湅湆湇湈湉湊湋湌湏湐湑湒湕湗湙湚湜湝湞湠湡湢湣湤湥湦湧湨湩湪湬湭湯湰湱湲湳湴湵湶湷湸湹湺湻湼湽満溁溂溄溇溈溊溋溌溍溎溑溒溓溔溕準溗溙溚溛溝溞溠溡溣溤溦溨溩溫溬溭溮溰溳溵溸溹溼溾溿滀滃滄滅滆滈滉滊滌滍滎滐滒滖滘滙滛滜滝滣滧滪滫滬滭滮滯" -- 0x9c
      , "滰滱滲滳滵滶滷滸滺滻滼滽滾滿漀漁漃漄漅漇漈漊漋漌漍漎漐漑漒漖漗漘漙漚漛漜漝漞漟漡漢漣漥漦漧漨漬漮漰漲漴漵漷漸漹漺漻漼漽漿潀潁潂\0潃潄潅潈潉潊潌潎潏潐潑潒潓潔潕潖潗潙潚潛潝潟潠潡潣潤潥潧潨潩潪潫潬潯潰潱潳潵潶潷潹潻潽潾潿澀澁澂澃澅澆澇澊澋澏澐澑澒澓澔澕澖澗澘澙澚澛澝澞澟澠澢澣澤澥澦澨澩澪澫澬澭澮澯澰澱澲澴澵澷澸澺澻澼澽澾澿濁濃濄濅濆濇濈濊濋濌濍濎濏濐濓濔濕濖濗濘濙濚濛濜濝濟濢濣濤濥" -- 0x9d
      , "濦濧濨濩濪濫濬濭濰濱濲濳濴濵濶濷濸濹濺濻濼濽濾濿瀀瀁瀂瀃瀄瀅瀆瀇瀈瀉瀊瀋瀌瀍瀎瀏瀐瀒瀓瀔瀕瀖瀗瀘瀙瀜瀝瀞瀟瀠瀡瀢瀤瀥瀦瀧瀨瀩瀪\0瀫瀬瀭瀮瀯瀰瀱瀲瀳瀴瀶瀷瀸瀺瀻瀼瀽瀾瀿灀灁灂灃灄灅灆灇灈灉灊灋灍灎灐灑灒灓灔灕灖灗灘灙灚灛灜灝灟灠灡灢灣灤灥灦灧灨灩灪灮灱灲灳灴灷灹灺灻災炁炂炃炄炆炇炈炋炌炍炏炐炑炓炗炘炚炛炞炟炠炡炢炣炤炥炦炧炨炩炪炰炲炴炵炶為炾炿烄烅烆烇烉烋烌烍烎烏烐烑烒烓烔烕烖烗烚" -- 0x9e
      , "烜烝烞烠烡烢烣烥烪烮烰烱烲烳烴烵烶烸烺烻烼烾烿焀焁焂焃焄焅焆焇焈焋焌焍焎焏焑焒焔焗焛焜焝焞焟焠無焢焣焤焥焧焨焩焪焫焬焭焮焲焳焴\0焵焷焸焹焺焻焼焽焾焿煀煁煂煃煄煆煇煈煉煋煍煏煐煑煒煓煔煕煖煗煘煙煚煛煝煟煠煡煢煣煥煩煪煫煬煭煯煰煱煴煵煶煷煹煻煼煾煿熀熁熂熃熅熆熇熈熉熋熌熍熎熐熑熒熓熕熖熗熚熛熜熝熞熡熢熣熤熥熦熧熩熪熫熭熮熯熰熱熲熴熶熷熸熺熻熼熽熾熿燀燁燂燄燅燆燇燈燉燊燋燌燍燏燐燑燒燓" -- 0x9f
      , "燖燗燘燙燚燛燜燝燞營燡燢燣燤燦燨燩燪燫燬燭燯燰燱燲燳燴燵燶燷燸燺燻燼燽燾燿爀爁爂爃爄爅爇爈爉爊爋爌爍爎爏爐爑爒爓爔爕爖爗爘爙爚\0爛爜爞爟爠爡爢爣爤爥爦爧爩爫爭爮爯爲爳爴爺爼爾牀牁牂牃牄牅牆牉牊牋牎牏牐牑牓牔牕牗牘牚牜牞牠牣牤牥牨牪牫牬牭牰牱牳牴牶牷牸牻牼牽犂犃犅犆犇犈犉犌犎犐犑犓犔犕犖犗犘犙犚犛犜犝犞犠犡犢犣犤犥犦犧犨犩犪犫犮犱犲犳犵犺犻犼犽犾犿狀狅狆狇狉狊狋狌狏狑狓狔狕狖狘狚狛" -- 0xa0
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\12288、。·ˉˇ¨〃々—～‖…‘’“”〔〕〈〉《》「」『』〖〗【】±×÷∶∧∨∑∏∪∩∈∷√⊥∥∠⌒⊙∫∮≡≌≈∽∝≠≮≯≤≥∞∵∴♂♀°′″℃＄¤￠￡‰§№☆★○●◎◇◆□■△▲※→←↑↓〓" -- 0xa1
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0ⅰⅱⅲⅳⅴⅵⅶⅷⅸⅹ\0\0\0\0\0\0\&⒈⒉⒊⒋⒌⒍⒎⒏⒐⒑⒒⒓⒔⒕⒖⒗⒘⒙⒚⒛⑴⑵⑶⑷⑸⑹⑺⑻⑼⑽⑾⑿⒀⒁⒂⒃⒄⒅⒆⒇①②③④⑤⑥⑦⑧⑨⑩\0\0㈠㈡㈢㈣㈤㈥㈦㈧㈨㈩\0\0ⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩⅪⅫ\0\0" -- 0xa2
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0！＂＃￥％＆＇（）＊＋，－．／０１２３４５６７８９：；＜＝＞？＠ＡＢＣＤＥＦＧＨＩＪＫＬＭＮＯＰＱＲＳＴＵＶＷＸＹＺ［＼］＾＿｀ａｂｃｄｅｆｇｈｉｊｋｌｍｎｏｐｑｒｓｔｕｖｗｘｙｚ｛｜｝￣" -- 0xa3
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0ぁあぃいぅうぇえぉおかがきぎくぐけげこごさざしじすずせぜそぞただちぢっつづてでとどなにぬねのはばぱひびぴふぶぷへべぺほぼぽまみむめもゃやゅゆょよらりるれろゎわゐゑをん\0\0\0\0\0\0\0\0\0\0\0" -- 0xa4
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0ァアィイゥウェエォオカガキギクグケゲコゴサザシジスズセゼソゾタダチヂッツヅテデトドナニヌネノハバパヒビピフブプヘベペホボポマミムメモャヤュユョヨラリルレロヮワヰヱヲンヴヵヶ\0\0\0\0\0\0\0\0" -- 0xa5
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0ΑΒΓΔΕΖΗΘΙΚΛΜΝΞΟΠΡΣΤΥΦΧΨΩ\0\0\0\0\0\0\0\0αβγδεζηθικλμνξοπρστυφχψω\0\0\0\0\0\0\0︵︶︹︺︿﹀︽︾﹁﹂﹃﹄\0\0︻︼︷︸︱\0︳︴\0\0\0\0\0\0\0\0\0" -- 0xa6
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0абвгдеёжзийклмнопрстуфхцчшщъыьэюя\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xa7
      , "ˊˋ˙–―‥‵℅℉↖↗↘↙∕∟∣≒≦≧⊿═║╒╓╔╕╖╗╘╙╚╛╜╝╞╟╠╡╢╣╤╥╦╧╨╩╪╫╬╭╮╯╰╱╲╳▁▂▃▄▅▆▇\0█▉▊▋▌▍▎▏▓▔▕▼▽◢◣◤◥☉⊕〒〝〞\0\0\0\0\0\0\0\0\0\0\0āáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜüêɑ\0ńň\0ɡ\0\0\0\0ㄅㄆㄇㄈㄉㄊㄋㄌㄍㄎㄏㄐㄑㄒㄓㄔㄕㄖㄗㄘㄙㄚㄛㄜㄝㄞㄟㄠㄡㄢㄣㄤㄥㄦㄧㄨㄩ\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xa8
      , "〡〢〣〤〥〦〧〨〩㊣㎎㎏㎜㎝㎞㎡㏄㏎㏑㏒㏕︰￢￤\0℡㈱\0‐\0\0\0ー゛゜ヽヾ〆ゝゞ﹉﹊﹋﹌﹍﹎﹏﹐﹑﹒﹔﹕﹖﹗﹙﹚﹛﹜﹝﹞﹟﹠﹡\0﹢﹣﹤﹥﹦﹨﹩﹪﹫\0\0\0\0\0\0\0\0\0\0\0\0\0〇\0\0\0\0\0\0\0\0\0\0\0\0\0─━│┃┄┅┆┇┈┉┊┋┌┍┎┏┐┑┒┓└┕┖┗┘┙┚┛├┝┞┟┠┡┢┣┤┥┦┧┨┩┪┫┬┭┮┯┰┱┲┳┴┵┶┷┸┹┺┻┼┽┾┿╀╁╂╃╄╅╆╇╈╉╊╋\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xa9
      , "狜狝狟狢狣狤狥狦狧狪狫狵狶狹狽狾狿猀猂猄猅猆猇猈猉猋猌猍猏猐猑猒猔猘猙猚猟猠猣猤猦猧猨猭猯猰猲猳猵猶猺猻猼猽獀獁獂獃獄獅獆獇獈\0獉獊獋獌獎獏獑獓獔獕獖獘獙獚獛獜獝獞獟獡獢獣獤獥獦獧獨獩獪獫獮獰獱\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xaa
      , "獲獳獴獵獶獷獸獹獺獻獼獽獿玀玁玂玃玅玆玈玊玌玍玏玐玒玓玔玕玗玘玙玚玜玝玞玠玡玣玤玥玦玧玨玪玬玭玱玴玵玶玸玹玼玽玾玿珁珃珄珅珆珇\0珋珌珎珒珓珔珕珖珗珘珚珛珜珝珟珡珢珣珤珦珨珪珫珬珮珯珰珱珳珴珵珶珷\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xab
      , "珸珹珺珻珼珽現珿琀琁琂琄琇琈琋琌琍琎琑琒琓琔琕琖琗琘琙琜琝琞琟琠琡琣琤琧琩琫琭琯琱琲琷琸琹琺琻琽琾琿瑀瑂瑃瑄瑅瑆瑇瑈瑉瑊瑋瑌瑍\0瑎瑏瑐瑑瑒瑓瑔瑖瑘瑝瑠瑡瑢瑣瑤瑥瑦瑧瑨瑩瑪瑫瑬瑮瑯瑱瑲瑳瑴瑵瑸瑹瑺\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xac
      , "瑻瑼瑽瑿璂璄璅璆璈璉璊璌璍璏璑璒璓璔璕璖璗璘璙璚璛璝璟璠璡璢璣璤璥璦璪璫璬璭璮璯環璱璲璳璴璵璶璷璸璹璻璼璽璾璿瓀瓁瓂瓃瓄瓅瓆瓇\0瓈瓉瓊瓋瓌瓍瓎瓏瓐瓑瓓瓔瓕瓖瓗瓘瓙瓚瓛瓝瓟瓡瓥瓧瓨瓩瓪瓫瓬瓭瓰瓱瓲\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xad
      , "瓳瓵瓸瓹瓺瓻瓼瓽瓾甀甁甂甃甅甆甇甈甉甊甋甌甎甐甒甔甕甖甗甛甝甞甠甡產産甤甦甧甪甮甴甶甹甼甽甿畁畂畃畄畆畇畉畊畍畐畑畒畓畕畖畗畘\0畝畞畟畠畡畢畣畤畧畨畩畫畬畭畮畯異畱畳畵當畷畺畻畼畽畾疀疁疂疄疅疇\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xae
      , "疈疉疊疌疍疎疐疓疕疘疛疜疞疢疦疧疨疩疪疭疶疷疺疻疿痀痁痆痋痌痎痏痐痑痓痗痙痚痜痝痟痠痡痥痩痬痭痮痯痲痳痵痶痷痸痺痻痽痾瘂瘄瘆瘇\0瘈瘉瘋瘍瘎瘏瘑瘒瘓瘔瘖瘚瘜瘝瘞瘡瘣瘧瘨瘬瘮瘯瘱瘲瘶瘷瘹瘺瘻瘽癁療癄\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xaf
      , "癅癆癇癈癉癊癋癎癏癐癑癒癓癕癗癘癙癚癛癝癟癠癡癢癤癥癦癧癨癩癪癬癭癮癰癱癲癳癴癵癶癷癹発發癿皀皁皃皅皉皊皌皍皏皐皒皔皕皗皘皚皛\0皜皝皞皟皠皡皢皣皥皦皧皨皩皪皫皬皭皯皰皳皵皶皷皸皹皺皻皼皽皾盀盁盃啊阿埃挨哎唉哀皑癌蔼矮艾碍爱隘鞍氨安俺按暗岸胺案肮昂盎凹敖熬翱袄傲奥懊澳芭捌扒叭吧笆八疤巴拔跋靶把耙坝霸罢爸白柏百摆佰败拜稗斑班搬扳般颁板版扮拌伴瓣半办绊邦帮梆榜膀绑棒磅蚌镑傍谤苞胞包褒剥" -- 0xb0
      , "盄盇盉盋盌盓盕盙盚盜盝盞盠盡盢監盤盦盧盨盩盪盫盬盭盰盳盵盶盷盺盻盽盿眀眂眃眅眆眊県眎眏眐眑眒眓眔眕眖眗眘眛眜眝眞眡眣眤眥眧眪眫\0眬眮眰眱眲眳眴眹眻眽眾眿睂睄睅睆睈睉睊睋睌睍睎睏睒睓睔睕睖睗睘睙睜薄雹保堡饱宝抱报暴豹鲍爆杯碑悲卑北辈背贝钡倍狈备惫焙被奔苯本笨崩绷甭泵蹦迸逼鼻比鄙笔彼碧蓖蔽毕毙毖币庇痹闭敝弊必辟壁臂避陛鞭边编贬扁便变卞辨辩辫遍标彪膘表鳖憋别瘪彬斌濒滨宾摈兵冰柄丙秉饼炳" -- 0xb1
      , "睝睞睟睠睤睧睩睪睭睮睯睰睱睲睳睴睵睶睷睸睺睻睼瞁瞂瞃瞆瞇瞈瞉瞊瞋瞏瞐瞓瞔瞕瞖瞗瞘瞙瞚瞛瞜瞝瞞瞡瞣瞤瞦瞨瞫瞭瞮瞯瞱瞲瞴瞶瞷瞸瞹瞺\0瞼瞾矀矁矂矃矄矅矆矇矈矉矊矋矌矎矏矐矑矒矓矔矕矖矘矙矚矝矞矟矠矡矤病并玻菠播拨钵波博勃搏铂箔伯帛舶脖膊渤泊驳捕卜哺补埠不布步簿部怖擦猜裁材才财睬踩采彩菜蔡餐参蚕残惭惨灿苍舱仓沧藏操糙槽曹草厕策侧册测层蹭插叉茬茶查碴搽察岔差诧拆柴豺搀掺蝉馋谗缠铲产阐颤昌猖" -- 0xb2
      , "矦矨矪矯矰矱矲矴矵矷矹矺矻矼砃砄砅砆砇砈砊砋砎砏砐砓砕砙砛砞砠砡砢砤砨砪砫砮砯砱砲砳砵砶砽砿硁硂硃硄硆硈硉硊硋硍硏硑硓硔硘硙硚\0硛硜硞硟硠硡硢硣硤硥硦硧硨硩硯硰硱硲硳硴硵硶硸硹硺硻硽硾硿碀碁碂碃场尝常长偿肠厂敞畅唱倡超抄钞朝嘲潮巢吵炒车扯撤掣彻澈郴臣辰尘晨忱沉陈趁衬撑称城橙成呈乘程惩澄诚承逞骋秤吃痴持匙池迟弛驰耻齿侈尺赤翅斥炽充冲虫崇宠抽酬畴踌稠愁筹仇绸瞅丑臭初出橱厨躇锄雏滁除楚" -- 0xb3
      , "碄碅碆碈碊碋碏碐碒碔碕碖碙碝碞碠碢碤碦碨碩碪碫碬碭碮碯碵碶碷碸確碻碼碽碿磀磂磃磄磆磇磈磌磍磎磏磑磒磓磖磗磘磚磛磜磝磞磟磠磡磢磣\0磤磥磦磧磩磪磫磭磮磯磰磱磳磵磶磸磹磻磼磽磾磿礀礂礃礄礆礇礈礉礊礋礌础储矗搐触处揣川穿椽传船喘串疮窗幢床闯创吹炊捶锤垂春椿醇唇淳纯蠢戳绰疵茨磁雌辞慈瓷词此刺赐次聪葱囱匆从丛凑粗醋簇促蹿篡窜摧崔催脆瘁粹淬翠村存寸磋撮搓措挫错搭达答瘩打大呆歹傣戴带殆代贷袋待逮" -- 0xb4
      , "礍礎礏礐礑礒礔礕礖礗礘礙礚礛礜礝礟礠礡礢礣礥礦礧礨礩礪礫礬礭礮礯礰礱礲礳礵礶礷礸礹礽礿祂祃祄祅祇祊祋祌祍祎祏祐祑祒祔祕祘祙祡祣\0祤祦祩祪祫祬祮祰祱祲祳祴祵祶祹祻祼祽祾祿禂禃禆禇禈禉禋禌禍禎禐禑禒怠耽担丹单郸掸胆旦氮但惮淡诞弹蛋当挡党荡档刀捣蹈倒岛祷导到稻悼道盗德得的蹬灯登等瞪凳邓堤低滴迪敌笛狄涤翟嫡抵底地蒂第帝弟递缔颠掂滇碘点典靛垫电佃甸店惦奠淀殿碉叼雕凋刁掉吊钓调跌爹碟蝶迭谍叠" -- 0xb5
      , "禓禔禕禖禗禘禙禛禜禝禞禟禠禡禢禣禤禥禦禨禩禪禫禬禭禮禯禰禱禲禴禵禶禷禸禼禿秂秄秅秇秈秊秌秎秏秐秓秔秖秗秙秚秛秜秝秞秠秡秢秥秨秪\0秬秮秱秲秳秴秵秶秷秹秺秼秾秿稁稄稅稇稈稉稊稌稏稐稑稒稓稕稖稘稙稛稜丁盯叮钉顶鼎锭定订丢东冬董懂动栋侗恫冻洞兜抖斗陡豆逗痘都督毒犊独读堵睹赌杜镀肚度渡妒端短锻段断缎堆兑队对墩吨蹲敦顿囤钝盾遁掇哆多夺垛躲朵跺舵剁惰堕蛾峨鹅俄额讹娥恶厄扼遏鄂饿恩而儿耳尔饵洱二" -- 0xb6
      , "稝稟稡稢稤稥稦稧稨稩稪稫稬稭種稯稰稱稲稴稵稶稸稺稾穀穁穂穃穄穅穇穈穉穊穋穌積穎穏穐穒穓穔穕穖穘穙穚穛穜穝穞穟穠穡穢穣穤穥穦穧穨\0穩穪穫穬穭穮穯穱穲穳穵穻穼穽穾窂窅窇窉窊窋窌窎窏窐窓窔窙窚窛窞窡窢贰发罚筏伐乏阀法珐藩帆番翻樊矾钒繁凡烦反返范贩犯饭泛坊芳方肪房防妨仿访纺放菲非啡飞肥匪诽吠肺废沸费芬酚吩氛分纷坟焚汾粉奋份忿愤粪丰封枫蜂峰锋风疯烽逢冯缝讽奉凤佛否夫敷肤孵扶拂辐幅氟符伏俘服" -- 0xb7
      , "窣窤窧窩窪窫窮窯窰窱窲窴窵窶窷窸窹窺窻窼窽窾竀竁竂竃竄竅竆竇竈竉竊竌竍竎竏竐竑竒竓竔竕竗竘竚竛竜竝竡竢竤竧竨竩竪竫竬竮竰竱竲竳\0竴竵競竷竸竻竼竾笀笁笂笅笇笉笌笍笎笐笒笓笖笗笘笚笜笝笟笡笢笣笧笩笭浮涪福袱弗甫抚辅俯釜斧脯腑府腐赴副覆赋复傅付阜父腹负富讣附妇缚咐噶嘎该改概钙盖溉干甘杆柑竿肝赶感秆敢赣冈刚钢缸肛纲岗港杠篙皋高膏羔糕搞镐稿告哥歌搁戈鸽胳疙割革葛格蛤阁隔铬个各给根跟耕更庚羹" -- 0xb8
      , "笯笰笲笴笵笶笷笹笻笽笿筀筁筂筃筄筆筈筊筍筎筓筕筗筙筜筞筟筡筣筤筥筦筧筨筩筪筫筬筭筯筰筳筴筶筸筺筼筽筿箁箂箃箄箆箇箈箉箊箋箌箎箏\0箑箒箓箖箘箙箚箛箞箟箠箣箤箥箮箯箰箲箳箵箶箷箹箺箻箼箽箾箿節篂篃範埂耿梗工攻功恭龚供躬公宫弓巩汞拱贡共钩勾沟苟狗垢构购够辜菇咕箍估沽孤姑鼓古蛊骨谷股故顾固雇刮瓜剐寡挂褂乖拐怪棺关官冠观管馆罐惯灌贯光广逛瑰规圭硅归龟闺轨鬼诡癸桂柜跪贵刽辊滚棍锅郭国果裹过哈" -- 0xb9
      , "篅篈築篊篋篍篎篏篐篒篔篕篖篗篘篛篜篞篟篠篢篣篤篧篨篩篫篬篭篯篰篲篳篴篵篶篸篹篺篻篽篿簀簁簂簃簄簅簆簈簉簊簍簎簐簑簒簓簔簕簗簘簙\0簚簛簜簝簞簠簡簢簣簤簥簨簩簫簬簭簮簯簰簱簲簳簴簵簶簷簹簺簻簼簽簾籂骸孩海氦亥害骇酣憨邯韩含涵寒函喊罕翰撼捍旱憾悍焊汗汉夯杭航壕嚎豪毫郝好耗号浩呵喝荷菏核禾和何合盒貉阂河涸赫褐鹤贺嘿黑痕很狠恨哼亨横衡恒轰哄烘虹鸿洪宏弘红喉侯猴吼厚候后呼乎忽瑚壶葫胡蝴狐糊湖" -- 0xba
      , "籃籄籅籆籇籈籉籊籋籌籎籏籐籑籒籓籔籕籖籗籘籙籚籛籜籝籞籟籠籡籢籣籤籥籦籧籨籩籪籫籬籭籮籯籰籱籲籵籶籷籸籹籺籾籿粀粁粂粃粄粅粆粇\0粈粊粋粌粍粎粏粐粓粔粖粙粚粛粠粡粣粦粧粨粩粫粬粭粯粰粴粵粶粷粸粺粻弧虎唬护互沪户花哗华猾滑画划化话槐徊怀淮坏欢环桓还缓换患唤痪豢焕涣宦幻荒慌黄磺蝗簧皇凰惶煌晃幌恍谎灰挥辉徽恢蛔回毁悔慧卉惠晦贿秽会烩汇讳诲绘荤昏婚魂浑混豁活伙火获或惑霍货祸击圾基机畸稽积箕" -- 0xbb
      , "粿糀糂糃糄糆糉糋糎糏糐糑糒糓糔糘糚糛糝糞糡糢糣糤糥糦糧糩糪糫糬糭糮糰糱糲糳糴糵糶糷糹糺糼糽糾糿紀紁紂紃約紅紆紇紈紉紋紌納紎紏紐\0紑紒紓純紕紖紗紘紙級紛紜紝紞紟紡紣紤紥紦紨紩紪紬紭紮細紱紲紳紴紵紶肌饥迹激讥鸡姬绩缉吉极棘辑籍集及急疾汲即嫉级挤几脊己蓟技冀季伎祭剂悸济寄寂计记既忌际妓继纪嘉枷夹佳家加荚颊贾甲钾假稼价架驾嫁歼监坚尖笺间煎兼肩艰奸缄茧检柬碱硷拣捡简俭剪减荐槛鉴践贱见键箭件" -- 0xbc
      , "紷紸紹紺紻紼紽紾紿絀絁終絃組絅絆絇絈絉絊絋経絍絎絏結絑絒絓絔絕絖絗絘絙絚絛絜絝絞絟絠絡絢絣絤絥給絧絨絩絪絫絬絭絯絰統絲絳絴絵絶\0絸絹絺絻絼絽絾絿綀綁綂綃綄綅綆綇綈綉綊綋綌綍綎綏綐綑綒經綔綕綖綗綘健舰剑饯渐溅涧建僵姜将浆江疆蒋桨奖讲匠酱降蕉椒礁焦胶交郊浇骄娇嚼搅铰矫侥脚狡角饺缴绞剿教酵轿较叫窖揭接皆秸街阶截劫节桔杰捷睫竭洁结解姐戒藉芥界借介疥诫届巾筋斤金今津襟紧锦仅谨进靳晋禁近烬浸" -- 0xbd
      , "継続綛綜綝綞綟綠綡綢綣綤綥綧綨綩綪綫綬維綯綰綱網綳綴綵綶綷綸綹綺綻綼綽綾綿緀緁緂緃緄緅緆緇緈緉緊緋緌緍緎総緐緑緒緓緔緕緖緗緘緙\0線緛緜緝緞緟締緡緢緣緤緥緦緧編緩緪緫緬緭緮緯緰緱緲緳練緵緶緷緸緹緺尽劲荆兢茎睛晶鲸京惊精粳经井警景颈静境敬镜径痉靖竟竞净炯窘揪究纠玖韭久灸九酒厩救旧臼舅咎就疚鞠拘狙疽居驹菊局咀矩举沮聚拒据巨具距踞锯俱句惧炬剧捐鹃娟倦眷卷绢撅攫抉掘倔爵觉决诀绝均菌钧军君峻" -- 0xbe
      , "緻緼緽緾緿縀縁縂縃縄縅縆縇縈縉縊縋縌縍縎縏縐縑縒縓縔縕縖縗縘縙縚縛縜縝縞縟縠縡縢縣縤縥縦縧縨縩縪縫縬縭縮縯縰縱縲縳縴縵縶縷縸縹\0縺縼總績縿繀繂繃繄繅繆繈繉繊繋繌繍繎繏繐繑繒繓織繕繖繗繘繙繚繛繜繝俊竣浚郡骏喀咖卡咯开揩楷凯慨刊堪勘坎砍看康慷糠扛抗亢炕考拷烤靠坷苛柯棵磕颗科壳咳可渴克刻客课肯啃垦恳坑吭空恐孔控抠口扣寇枯哭窟苦酷库裤夸垮挎跨胯块筷侩快宽款匡筐狂框矿眶旷况亏盔岿窥葵奎魁傀" -- 0xbf
      , "繞繟繠繡繢繣繤繥繦繧繨繩繪繫繬繭繮繯繰繱繲繳繴繵繶繷繸繹繺繻繼繽繾繿纀纁纃纄纅纆纇纈纉纊纋續纍纎纏纐纑纒纓纔纕纖纗纘纙纚纜纝纞\0纮纴纻纼绖绤绬绹缊缐缞缷缹缻缼缽缾缿罀罁罃罆罇罈罉罊罋罌罍罎罏罒罓馈愧溃坤昆捆困括扩廓阔垃拉喇蜡腊辣啦莱来赖蓝婪栏拦篮阑兰澜谰揽览懒缆烂滥琅榔狼廊郎朗浪捞劳牢老佬姥酪烙涝勒乐雷镭蕾磊累儡垒擂肋类泪棱楞冷厘梨犁黎篱狸离漓理李里鲤礼莉荔吏栗丽厉励砾历利傈例俐" -- 0xc0
      , "罖罙罛罜罝罞罠罣罤罥罦罧罫罬罭罯罰罳罵罶罷罸罺罻罼罽罿羀羂羃羄羅羆羇羈羉羋羍羏羐羑羒羓羕羖羗羘羙羛羜羠羢羣羥羦羨義羪羫羬羭羮羱\0羳羴羵羶羷羺羻羾翀翂翃翄翆翇翈翉翋翍翏翐翑習翓翖翗翙翚翛翜翝翞翢翣痢立粒沥隶力璃哩俩联莲连镰廉怜涟帘敛脸链恋炼练粮凉梁粱良两辆量晾亮谅撩聊僚疗燎寥辽潦了撂镣廖料列裂烈劣猎琳林磷霖临邻鳞淋凛赁吝拎玲菱零龄铃伶羚凌灵陵岭领另令溜琉榴硫馏留刘瘤流柳六龙聋咙笼窿" -- 0xc1
      , "翤翧翨翪翫翬翭翯翲翴翵翶翷翸翹翺翽翾翿耂耇耈耉耊耎耏耑耓耚耛耝耞耟耡耣耤耫耬耭耮耯耰耲耴耹耺耼耾聀聁聄聅聇聈聉聎聏聐聑聓聕聖聗\0聙聛聜聝聞聟聠聡聢聣聤聥聦聧聨聫聬聭聮聯聰聲聳聴聵聶職聸聹聺聻聼聽隆垄拢陇楼娄搂篓漏陋芦卢颅庐炉掳卤虏鲁麓碌露路赂鹿潞禄录陆戮驴吕铝侣旅履屡缕虑氯律率滤绿峦挛孪滦卵乱掠略抡轮伦仑沦纶论萝螺罗逻锣箩骡裸落洛骆络妈麻玛码蚂马骂嘛吗埋买麦卖迈脉瞒馒蛮满蔓曼慢漫" -- 0xc2
      , "聾肁肂肅肈肊肍肎肏肐肑肒肔肕肗肙肞肣肦肧肨肬肰肳肵肶肸肹肻胅胇胈胉胊胋胏胐胑胒胓胔胕胘胟胠胢胣胦胮胵胷胹胻胾胿脀脁脃脄脅脇脈脋\0脌脕脗脙脛脜脝脟脠脡脢脣脤脥脦脧脨脩脪脫脭脮脰脳脴脵脷脹脺脻脼脽脿谩芒茫盲氓忙莽猫茅锚毛矛铆卯茂冒帽貌贸么玫枚梅酶霉煤没眉媒镁每美昧寐妹媚门闷们萌蒙檬盟锰猛梦孟眯醚靡糜迷谜弥米秘觅泌蜜密幂棉眠绵冕免勉娩缅面苗描瞄藐秒渺庙妙蔑灭民抿皿敏悯闽明螟鸣铭名命谬摸" -- 0xc3
      , "腀腁腂腃腄腅腇腉腍腎腏腒腖腗腘腛腜腝腞腟腡腢腣腤腦腨腪腫腬腯腲腳腵腶腷腸膁膃膄膅膆膇膉膋膌膍膎膐膒膓膔膕膖膗膙膚膞膟膠膡膢膤膥\0膧膩膫膬膭膮膯膰膱膲膴膵膶膷膸膹膼膽膾膿臄臅臇臈臉臋臍臎臏臐臑臒臓摹蘑模膜磨摩魔抹末莫墨默沫漠寞陌谋牟某拇牡亩姆母墓暮幕募慕木目睦牧穆拿哪呐钠那娜纳氖乃奶耐奈南男难囊挠脑恼闹淖呢馁内嫩能妮霓倪泥尼拟你匿腻逆溺蔫拈年碾撵捻念娘酿鸟尿捏聂孽啮镊镍涅您柠狞凝宁" -- 0xc4
      , "臔臕臖臗臘臙臚臛臜臝臞臟臠臡臢臤臥臦臨臩臫臮臯臰臱臲臵臶臷臸臹臺臽臿舃與興舉舊舋舎舏舑舓舕舖舗舘舙舚舝舠舤舥舦舧舩舮舲舺舼舽舿\0艀艁艂艃艅艆艈艊艌艍艎艐艑艒艓艔艕艖艗艙艛艜艝艞艠艡艢艣艤艥艦艧艩拧泞牛扭钮纽脓浓农弄奴努怒女暖虐疟挪懦糯诺哦欧鸥殴藕呕偶沤啪趴爬帕怕琶拍排牌徘湃派攀潘盘磐盼畔判叛乓庞旁耪胖抛咆刨炮袍跑泡呸胚培裴赔陪配佩沛喷盆砰抨烹澎彭蓬棚硼篷膨朋鹏捧碰坯砒霹批披劈琵毗" -- 0xc5
      , "艪艫艬艭艱艵艶艷艸艻艼芀芁芃芅芆芇芉芌芐芓芔芕芖芚芛芞芠芢芣芧芲芵芶芺芻芼芿苀苂苃苅苆苉苐苖苙苚苝苢苧苨苩苪苬苭苮苰苲苳苵苶苸\0苺苼苽苾苿茀茊茋茍茐茒茓茖茘茙茝茞茟茠茡茢茣茤茥茦茩茪茮茰茲茷茻茽啤脾疲皮匹痞僻屁譬篇偏片骗飘漂瓢票撇瞥拼频贫品聘乒坪苹萍平凭瓶评屏坡泼颇婆破魄迫粕剖扑铺仆莆葡菩蒲埔朴圃普浦谱曝瀑期欺栖戚妻七凄漆柒沏其棋奇歧畦崎脐齐旗祈祁骑起岂乞企启契砌器气迄弃汽泣讫掐" -- 0xc6
      , "茾茿荁荂荄荅荈荊荋荌荍荎荓荕荖荗荘荙荝荢荰荱荲荳荴荵荶荹荺荾荿莀莁莂莃莄莇莈莊莋莌莍莏莐莑莔莕莖莗莙莚莝莟莡莢莣莤莥莦莧莬莭莮\0莯莵莻莾莿菂菃菄菆菈菉菋菍菎菐菑菒菓菕菗菙菚菛菞菢菣菤菦菧菨菫菬菭恰洽牵扦钎铅千迁签仟谦乾黔钱钳前潜遣浅谴堑嵌欠歉枪呛腔羌墙蔷强抢橇锹敲悄桥瞧乔侨巧鞘撬翘峭俏窍切茄且怯窃钦侵亲秦琴勤芹擒禽寝沁青轻氢倾卿清擎晴氰情顷请庆琼穷秋丘邱球求囚酋泅趋区蛆曲躯屈驱渠" -- 0xc7
      , "菮華菳菴菵菶菷菺菻菼菾菿萀萂萅萇萈萉萊萐萒萓萔萕萖萗萙萚萛萞萟萠萡萢萣萩萪萫萬萭萮萯萰萲萳萴萵萶萷萹萺萻萾萿葀葁葂葃葄葅葇葈葉\0葊葋葌葍葎葏葐葒葓葔葕葖葘葝葞葟葠葢葤葥葦葧葨葪葮葯葰葲葴葷葹葻葼取娶龋趣去圈颧权醛泉全痊拳犬券劝缺炔瘸却鹊榷确雀裙群然燃冉染瓤壤攘嚷让饶扰绕惹热壬仁人忍韧任认刃妊纫扔仍日戎茸蓉荣融熔溶容绒冗揉柔肉茹蠕儒孺如辱乳汝入褥软阮蕊瑞锐闰润若弱撒洒萨腮鳃塞赛三叁" -- 0xc8
      , "葽葾葿蒀蒁蒃蒄蒅蒆蒊蒍蒏蒐蒑蒒蒓蒔蒕蒖蒘蒚蒛蒝蒞蒟蒠蒢蒣蒤蒥蒦蒧蒨蒩蒪蒫蒬蒭蒮蒰蒱蒳蒵蒶蒷蒻蒼蒾蓀蓂蓃蓅蓆蓇蓈蓋蓌蓎蓏蓒蓔蓕蓗\0蓘蓙蓚蓛蓜蓞蓡蓢蓤蓧蓨蓩蓪蓫蓭蓮蓯蓱蓲蓳蓴蓵蓶蓷蓸蓹蓺蓻蓽蓾蔀蔁蔂伞散桑嗓丧搔骚扫嫂瑟色涩森僧莎砂杀刹沙纱傻啥煞筛晒珊苫杉山删煽衫闪陕擅赡膳善汕扇缮墒伤商赏晌上尚裳梢捎稍烧芍勺韶少哨邵绍奢赊蛇舌舍赦摄射慑涉社设砷申呻伸身深娠绅神沈审婶甚肾慎渗声生甥牲升绳" -- 0xc9
      , "蔃蔄蔅蔆蔇蔈蔉蔊蔋蔍蔎蔏蔐蔒蔔蔕蔖蔘蔙蔛蔜蔝蔞蔠蔢蔣蔤蔥蔦蔧蔨蔩蔪蔭蔮蔯蔰蔱蔲蔳蔴蔵蔶蔾蔿蕀蕁蕂蕄蕅蕆蕇蕋蕌蕍蕎蕏蕐蕑蕒蕓蕔蕕\0蕗蕘蕚蕛蕜蕝蕟蕠蕡蕢蕣蕥蕦蕧蕩蕪蕫蕬蕭蕮蕯蕰蕱蕳蕵蕶蕷蕸蕼蕽蕿薀薁省盛剩胜圣师失狮施湿诗尸虱十石拾时什食蚀实识史矢使屎驶始式示士世柿事拭誓逝势是嗜噬适仕侍释饰氏市恃室视试收手首守寿授售受瘦兽蔬枢梳殊抒输叔舒淑疏书赎孰熟薯暑曙署蜀黍鼠属术述树束戍竖墅庶数漱" -- 0xca
      , "薂薃薆薈薉薊薋薌薍薎薐薑薒薓薔薕薖薗薘薙薚薝薞薟薠薡薢薣薥薦薧薩薫薬薭薱薲薳薴薵薶薸薺薻薼薽薾薿藀藂藃藄藅藆藇藈藊藋藌藍藎藑藒\0藔藖藗藘藙藚藛藝藞藟藠藡藢藣藥藦藧藨藪藫藬藭藮藯藰藱藲藳藴藵藶藷藸恕刷耍摔衰甩帅栓拴霜双爽谁水睡税吮瞬顺舜说硕朔烁斯撕嘶思私司丝死肆寺嗣四伺似饲巳松耸怂颂送宋讼诵搜艘擞嗽苏酥俗素速粟僳塑溯宿诉肃酸蒜算虽隋随绥髓碎岁穗遂隧祟孙损笋蓑梭唆缩琐索锁所塌他它她塔" -- 0xcb
      , "藹藺藼藽藾蘀蘁蘂蘃蘄蘆蘇蘈蘉蘊蘋蘌蘍蘎蘏蘐蘒蘓蘔蘕蘗蘘蘙蘚蘛蘜蘝蘞蘟蘠蘡蘢蘣蘤蘥蘦蘨蘪蘫蘬蘭蘮蘯蘰蘱蘲蘳蘴蘵蘶蘷蘹蘺蘻蘽蘾蘿虀\0虁虂虃虄虅虆虇虈虉虊虋虌虒虓處虖虗虘虙虛虜虝號虠虡虣虤虥虦虧虨虩虪獭挞蹋踏胎苔抬台泰酞太态汰坍摊贪瘫滩坛檀痰潭谭谈坦毯袒碳探叹炭汤塘搪堂棠膛唐糖倘躺淌趟烫掏涛滔绦萄桃逃淘陶讨套特藤腾疼誊梯剔踢锑提题蹄啼体替嚏惕涕剃屉天添填田甜恬舔腆挑条迢眺跳贴铁帖厅听烃" -- 0xcc
      , "虭虯虰虲虳虴虵虶虷虸蚃蚄蚅蚆蚇蚈蚉蚎蚏蚐蚑蚒蚔蚖蚗蚘蚙蚚蚛蚞蚟蚠蚡蚢蚥蚦蚫蚭蚮蚲蚳蚷蚸蚹蚻蚼蚽蚾蚿蛁蛂蛃蛅蛈蛌蛍蛒蛓蛕蛖蛗蛚蛜\0蛝蛠蛡蛢蛣蛥蛦蛧蛨蛪蛫蛬蛯蛵蛶蛷蛺蛻蛼蛽蛿蜁蜄蜅蜆蜋蜌蜎蜏蜐蜑蜔蜖汀廷停亭庭挺艇通桐酮瞳同铜彤童桶捅筒统痛偷投头透凸秃突图徒途涂屠土吐兔湍团推颓腿蜕褪退吞屯臀拖托脱鸵陀驮驼椭妥拓唾挖哇蛙洼娃瓦袜歪外豌弯湾玩顽丸烷完碗挽晚皖惋宛婉万腕汪王亡枉网往旺望忘妄威" -- 0xcd
      , "蜙蜛蜝蜟蜠蜤蜦蜧蜨蜪蜫蜬蜭蜯蜰蜲蜳蜵蜶蜸蜹蜺蜼蜽蝀蝁蝂蝃蝄蝅蝆蝊蝋蝍蝏蝐蝑蝒蝔蝕蝖蝘蝚蝛蝜蝝蝞蝟蝡蝢蝦蝧蝨蝩蝪蝫蝬蝭蝯蝱蝲蝳蝵\0蝷蝸蝹蝺蝿螀螁螄螆螇螉螊螌螎螏螐螑螒螔螕螖螘螙螚螛螜螝螞螠螡螢螣螤巍微危韦违桅围唯惟为潍维苇萎委伟伪尾纬未蔚味畏胃喂魏位渭谓尉慰卫瘟温蚊文闻纹吻稳紊问嗡翁瓮挝蜗涡窝我斡卧握沃巫呜钨乌污诬屋无芜梧吾吴毋武五捂午舞伍侮坞戊雾晤物勿务悟误昔熙析西硒矽晰嘻吸锡牺" -- 0xce
      , "螥螦螧螩螪螮螰螱螲螴螶螷螸螹螻螼螾螿蟁蟂蟃蟄蟅蟇蟈蟉蟌蟍蟎蟏蟐蟔蟕蟖蟗蟘蟙蟚蟜蟝蟞蟟蟡蟢蟣蟤蟦蟧蟨蟩蟫蟬蟭蟯蟰蟱蟲蟳蟴蟵蟶蟷蟸\0蟺蟻蟼蟽蟿蠀蠁蠂蠄蠅蠆蠇蠈蠉蠋蠌蠍蠎蠏蠐蠑蠒蠔蠗蠘蠙蠚蠜蠝蠞蠟蠠蠣稀息希悉膝夕惜熄烯溪汐犀檄袭席习媳喜铣洗系隙戏细瞎虾匣霞辖暇峡侠狭下厦夏吓掀锨先仙鲜纤咸贤衔舷闲涎弦嫌显险现献县腺馅羡宪陷限线相厢镶香箱襄湘乡翔祥详想响享项巷橡像向象萧硝霄削哮嚣销消宵淆晓" -- 0xcf
      , "蠤蠥蠦蠧蠨蠩蠪蠫蠬蠭蠮蠯蠰蠱蠳蠴蠵蠶蠷蠸蠺蠻蠽蠾蠿衁衂衃衆衇衈衉衊衋衎衏衐衑衒術衕衖衘衚衛衜衝衞衟衠衦衧衪衭衯衱衳衴衵衶衸衹衺\0衻衼袀袃袆袇袉袊袌袎袏袐袑袓袔袕袗袘袙袚袛袝袞袟袠袡袣袥袦袧袨袩袪小孝校肖啸笑效楔些歇蝎鞋协挟携邪斜胁谐写械卸蟹懈泄泻谢屑薪芯锌欣辛新忻心信衅星腥猩惺兴刑型形邢行醒幸杏性姓兄凶胸匈汹雄熊休修羞朽嗅锈秀袖绣墟戌需虚嘘须徐许蓄酗叙旭序畜恤絮婿绪续轩喧宣悬旋玄" -- 0xd0
      , "袬袮袯袰袲袳袴袵袶袸袹袺袻袽袾袿裀裃裄裇裈裊裋裌裍裏裐裑裓裖裗裚裛補裝裞裠裡裦裧裩裪裫裬裭裮裯裲裵裶裷裺裻製裿褀褁褃褄褅褆複褈\0褉褋褌褍褎褏褑褔褕褖褗褘褜褝褞褟褠褢褣褤褦褧褨褩褬褭褮褯褱褲褳褵褷选癣眩绚靴薛学穴雪血勋熏循旬询寻驯巡殉汛训讯逊迅压押鸦鸭呀丫芽牙蚜崖衙涯雅哑亚讶焉咽阉烟淹盐严研蜒岩延言颜阎炎沿奄掩眼衍演艳堰燕厌砚雁唁彦焰宴谚验殃央鸯秧杨扬佯疡羊洋阳氧仰痒养样漾邀腰妖瑶" -- 0xd1
      , "褸褹褺褻褼褽褾褿襀襂襃襅襆襇襈襉襊襋襌襍襎襏襐襑襒襓襔襕襖襗襘襙襚襛襜襝襠襡襢襣襤襥襧襨襩襪襫襬襭襮襯襰襱襲襳襴襵襶襷襸襹襺襼\0襽襾覀覂覄覅覇覈覉覊見覌覍覎規覐覑覒覓覔覕視覗覘覙覚覛覜覝覞覟覠覡摇尧遥窑谣姚咬舀药要耀椰噎耶爷野冶也页掖业叶曳腋夜液一壹医揖铱依伊衣颐夷遗移仪胰疑沂宜姨彝椅蚁倚已乙矣以艺抑易邑屹亿役臆逸肄疫亦裔意毅忆义益溢诣议谊译异翼翌绎茵荫因殷音阴姻吟银淫寅饮尹引隐" -- 0xd2
      , "覢覣覤覥覦覧覨覩親覫覬覭覮覯覰覱覲観覴覵覶覷覸覹覺覻覼覽覾覿觀觃觍觓觔觕觗觘觙觛觝觟觠觡觢觤觧觨觩觪觬觭觮觰觱觲觴觵觶觷觸觹觺\0觻觼觽觾觿訁訂訃訄訅訆計訉訊訋訌訍討訏訐訑訒訓訔訕訖託記訙訚訛訜訝印英樱婴鹰应缨莹萤营荧蝇迎赢盈影颖硬映哟拥佣臃痈庸雍踊蛹咏泳涌永恿勇用幽优悠忧尤由邮铀犹油游酉有友右佑釉诱又幼迂淤于盂榆虞愚舆余俞逾鱼愉渝渔隅予娱雨与屿禹宇语羽玉域芋郁吁遇喻峪御愈欲狱育誉" -- 0xd3
      , "訞訟訠訡訢訣訤訥訦訧訨訩訪訫訬設訮訯訰許訲訳訴訵訶訷訸訹診註証訽訿詀詁詂詃詄詅詆詇詉詊詋詌詍詎詏詐詑詒詓詔評詖詗詘詙詚詛詜詝詞\0詟詠詡詢詣詤詥試詧詨詩詪詫詬詭詮詯詰話該詳詴詵詶詷詸詺詻詼詽詾詿誀浴寓裕预豫驭鸳渊冤元垣袁原援辕园员圆猿源缘远苑愿怨院曰约越跃钥岳粤月悦阅耘云郧匀陨允运蕴酝晕韵孕匝砸杂栽哉灾宰载再在咱攒暂赞赃脏葬遭糟凿藻枣早澡蚤躁噪造皂灶燥责择则泽贼怎增憎曾赠扎喳渣札轧" -- 0xd4
      , "誁誂誃誄誅誆誇誈誋誌認誎誏誐誑誒誔誕誖誗誘誙誚誛誜誝語誟誠誡誢誣誤誥誦誧誨誩說誫説読誮誯誰誱課誳誴誵誶誷誸誹誺誻誼誽誾調諀諁諂\0諃諄諅諆談諈諉諊請諌諍諎諏諐諑諒諓諔諕論諗諘諙諚諛諜諝諞諟諠諡諢諣铡闸眨栅榨咋乍炸诈摘斋宅窄债寨瞻毡詹粘沾盏斩辗崭展蘸栈占战站湛绽樟章彰漳张掌涨杖丈帐账仗胀瘴障招昭找沼赵照罩兆肇召遮折哲蛰辙者锗蔗这浙珍斟真甄砧臻贞针侦枕疹诊震振镇阵蒸挣睁征狰争怔整拯正政" -- 0xd5
      , "諤諥諦諧諨諩諪諫諬諭諮諯諰諱諲諳諴諵諶諷諸諹諺諻諼諽諾諿謀謁謂謃謄謅謆謈謉謊謋謌謍謎謏謐謑謒謓謔謕謖謗謘謙謚講謜謝謞謟謠謡謢謣\0謤謥謧謨謩謪謫謬謭謮謯謰謱謲謳謴謵謶謷謸謹謺謻謼謽謾謿譀譁譂譃譄譅帧症郑证芝枝支吱蜘知肢脂汁之织职直植殖执值侄址指止趾只旨纸志挚掷至致置帜峙制智秩稚质炙痔滞治窒中盅忠钟衷终种肿重仲众舟周州洲诌粥轴肘帚咒皱宙昼骤珠株蛛朱猪诸诛逐竹烛煮拄瞩嘱主著柱助蛀贮铸筑" -- 0xd6
      , "譆譇譈證譊譋譌譍譎譏譐譑譒譓譔譕譖譗識譙譚譛譜譝譞譟譠譡譢譣譤譥譧譨譩譪譫譭譮譯議譱譲譳譴譵譶護譸譹譺譻譼譽譾譿讀讁讂讃讄讅讆\0讇讈讉變讋讌讍讎讏讐讑讒讓讔讕讖讗讘讙讚讛讜讝讞讟讬讱讻诇诐诪谉谞住注祝驻抓爪拽专砖转撰赚篆桩庄装妆撞壮状椎锥追赘坠缀谆准捉拙卓桌琢茁酌啄着灼浊兹咨资姿滋淄孜紫仔籽滓子自渍字鬃棕踪宗综总纵邹走奏揍租足卒族祖诅阻组钻纂嘴醉最罪尊遵昨左佐柞做作坐座\0\0\0\0\0" -- 0xd7
      , "谸谹谺谻谼谽谾谿豀豂豃豄豅豈豊豋豍豎豏豐豑豒豓豔豖豗豘豙豛豜豝豞豟豠豣豤豥豦豧豨豩豬豭豮豯豰豱豲豴豵豶豷豻豼豽豾豿貀貁貃貄貆貇\0貈貋貍貎貏貐貑貒貓貕貖貗貙貚貛貜貝貞貟負財貢貣貤貥貦貧貨販貪貫責貭亍丌兀丐廿卅丕亘丞鬲孬噩丨禺丿匕乇夭爻卮氐囟胤馗毓睾鼗丶亟鼐乜乩亓芈孛啬嘏仄厍厝厣厥厮靥赝匚叵匦匮匾赜卦卣刂刈刎刭刳刿剀剌剞剡剜蒯剽劂劁劐劓冂罔亻仃仉仂仨仡仫仞伛仳伢佤仵伥伧伉伫佞佧攸佚佝" -- 0xd8
      , "貮貯貰貱貲貳貴貵貶買貸貹貺費貼貽貾貿賀賁賂賃賄賅賆資賈賉賊賋賌賍賎賏賐賑賒賓賔賕賖賗賘賙賚賛賜賝賞賟賠賡賢賣賤賥賦賧賨賩質賫賬\0賭賮賯賰賱賲賳賴賵賶賷賸賹賺賻購賽賾賿贀贁贂贃贄贅贆贇贈贉贊贋贌贍佟佗伲伽佶佴侑侉侃侏佾佻侪佼侬侔俦俨俪俅俚俣俜俑俟俸倩偌俳倬倏倮倭俾倜倌倥倨偾偃偕偈偎偬偻傥傧傩傺僖儆僭僬僦僮儇儋仝氽佘佥俎龠汆籴兮巽黉馘冁夔勹匍訇匐凫夙兕亠兖亳衮袤亵脔裒禀嬴蠃羸冫冱冽冼" -- 0xd9
      , "贎贏贐贑贒贓贔贕贖贗贘贙贚贛贜贠赑赒赗赟赥赨赩赪赬赮赯赱赲赸赹赺赻赼赽赾赿趀趂趃趆趇趈趉趌趍趎趏趐趒趓趕趖趗趘趙趚趛趜趝趞趠趡\0趢趤趥趦趧趨趩趪趫趬趭趮趯趰趲趶趷趹趻趽跀跁跂跅跇跈跉跊跍跐跒跓跔凇冖冢冥讠讦讧讪讴讵讷诂诃诋诏诎诒诓诔诖诘诙诜诟诠诤诨诩诮诰诳诶诹诼诿谀谂谄谇谌谏谑谒谔谕谖谙谛谘谝谟谠谡谥谧谪谫谮谯谲谳谵谶卩卺阝阢阡阱阪阽阼陂陉陔陟陧陬陲陴隈隍隗隰邗邛邝邙邬邡邴邳邶邺" -- 0xda
      , "跕跘跙跜跠跡跢跥跦跧跩跭跮跰跱跲跴跶跼跾跿踀踁踂踃踄踆踇踈踋踍踎踐踑踒踓踕踖踗踘踙踚踛踜踠踡踤踥踦踧踨踫踭踰踲踳踴踶踷踸踻踼踾\0踿蹃蹅蹆蹌蹍蹎蹏蹐蹓蹔蹕蹖蹗蹘蹚蹛蹜蹝蹞蹟蹠蹡蹢蹣蹤蹥蹧蹨蹪蹫蹮蹱邸邰郏郅邾郐郄郇郓郦郢郜郗郛郫郯郾鄄鄢鄞鄣鄱鄯鄹酃酆刍奂劢劬劭劾哿勐勖勰叟燮矍廴凵凼鬯厶弁畚巯坌垩垡塾墼壅壑圩圬圪圳圹圮圯坜圻坂坩垅坫垆坼坻坨坭坶坳垭垤垌垲埏垧垴垓垠埕埘埚埙埒垸埴埯埸埤埝" -- 0xdb
      , "蹳蹵蹷蹸蹹蹺蹻蹽蹾躀躂躃躄躆躈躉躊躋躌躍躎躑躒躓躕躖躗躘躙躚躛躝躟躠躡躢躣躤躥躦躧躨躩躪躭躮躰躱躳躴躵躶躷躸躹躻躼躽躾躿軀軁軂\0軃軄軅軆軇軈軉車軋軌軍軏軐軑軒軓軔軕軖軗軘軙軚軛軜軝軞軟軠軡転軣軤堋堍埽埭堀堞堙塄堠塥塬墁墉墚墀馨鼙懿艹艽艿芏芊芨芄芎芑芗芙芫芸芾芰苈苊苣芘芷芮苋苌苁芩芴芡芪芟苄苎芤苡茉苷苤茏茇苜苴苒苘茌苻苓茑茚茆茔茕苠苕茜荑荛荜茈莒茼茴茱莛荞茯荏荇荃荟荀茗荠茭茺茳荦荥" -- 0xdc
      , "軥軦軧軨軩軪軫軬軭軮軯軰軱軲軳軴軵軶軷軸軹軺軻軼軽軾軿輀輁輂較輄輅輆輇輈載輊輋輌輍輎輏輐輑輒輓輔輕輖輗輘輙輚輛輜輝輞輟輠輡輢輣\0輤輥輦輧輨輩輪輫輬輭輮輯輰輱輲輳輴輵輶輷輸輹輺輻輼輽輾輿轀轁轂轃轄荨茛荩荬荪荭荮莰荸莳莴莠莪莓莜莅荼莶莩荽莸荻莘莞莨莺莼菁萁菥菘堇萘萋菝菽菖萜萸萑萆菔菟萏萃菸菹菪菅菀萦菰菡葜葑葚葙葳蒇蒈葺蒉葸萼葆葩葶蒌蒎萱葭蓁蓍蓐蓦蒽蓓蓊蒿蒺蓠蒡蒹蒴蒗蓥蓣蔌甍蔸蓰蔹蔟蔺" -- 0xdd
      , "轅轆轇轈轉轊轋轌轍轎轏轐轑轒轓轔轕轖轗轘轙轚轛轜轝轞轟轠轡轢轣轤轥轪辀辌辒辝辠辡辢辤辥辦辧辪辬辭辮辯農辳辴辵辷辸辺辻込辿迀迃迆\0迉迊迋迌迍迏迒迖迗迚迠迡迣迧迬迯迱迲迴迵迶迺迻迼迾迿逇逈逌逎逓逕逘蕖蔻蓿蓼蕙蕈蕨蕤蕞蕺瞢蕃蕲蕻薤薨薇薏蕹薮薜薅薹薷薰藓藁藜藿蘧蘅蘩蘖蘼廾弈夼奁耷奕奚奘匏尢尥尬尴扌扪抟抻拊拚拗拮挢拶挹捋捃掭揶捱捺掎掴捭掬掊捩掮掼揲揸揠揿揄揞揎摒揆掾摅摁搋搛搠搌搦搡摞撄摭撖" -- 0xde
      , "這逜連逤逥逧逨逩逪逫逬逰週進逳逴逷逹逺逽逿遀遃遅遆遈遉遊運遌過達違遖遙遚遜遝遞遟遠遡遤遦遧適遪遫遬遯遰遱遲遳遶遷選遹遺遻遼遾邁\0還邅邆邇邉邊邌邍邎邏邐邒邔邖邘邚邜邞邟邠邤邥邧邨邩邫邭邲邷邼邽邿郀摺撷撸撙撺擀擐擗擤擢攉攥攮弋忒甙弑卟叱叽叩叨叻吒吖吆呋呒呓呔呖呃吡呗呙吣吲咂咔呷呱呤咚咛咄呶呦咝哐咭哂咴哒咧咦哓哔呲咣哕咻咿哌哙哚哜咩咪咤哝哏哞唛哧唠哽唔哳唢唣唏唑唧唪啧喏喵啉啭啁啕唿啐唼" -- 0xdf
      , "郂郃郆郈郉郋郌郍郒郔郕郖郘郙郚郞郟郠郣郤郥郩郪郬郮郰郱郲郳郵郶郷郹郺郻郼郿鄀鄁鄃鄅鄆鄇鄈鄉鄊鄋鄌鄍鄎鄏鄐鄑鄒鄓鄔鄕鄖鄗鄘鄚鄛鄜\0鄝鄟鄠鄡鄤鄥鄦鄧鄨鄩鄪鄫鄬鄭鄮鄰鄲鄳鄴鄵鄶鄷鄸鄺鄻鄼鄽鄾鄿酀酁酂酄唷啖啵啶啷唳唰啜喋嗒喃喱喹喈喁喟啾嗖喑啻嗟喽喾喔喙嗪嗷嗉嘟嗑嗫嗬嗔嗦嗝嗄嗯嗥嗲嗳嗌嗍嗨嗵嗤辔嘞嘈嘌嘁嘤嘣嗾嘀嘧嘭噘嘹噗嘬噍噢噙噜噌噔嚆噤噱噫噻噼嚅嚓嚯囔囗囝囡囵囫囹囿圄圊圉圜帏帙帔帑帱帻帼" -- 0xe0
      , "酅酇酈酑酓酔酕酖酘酙酛酜酟酠酦酧酨酫酭酳酺酻酼醀醁醂醃醄醆醈醊醎醏醓醔醕醖醗醘醙醜醝醞醟醠醡醤醥醦醧醨醩醫醬醰醱醲醳醶醷醸醹醻\0醼醽醾醿釀釁釂釃釄釅釆釈釋釐釒釓釔釕釖釗釘釙釚釛針釞釟釠釡釢釣釤釥帷幄幔幛幞幡岌屺岍岐岖岈岘岙岑岚岜岵岢岽岬岫岱岣峁岷峄峒峤峋峥崂崃崧崦崮崤崞崆崛嵘崾崴崽嵬嵛嵯嵝嵫嵋嵊嵩嵴嶂嶙嶝豳嶷巅彳彷徂徇徉後徕徙徜徨徭徵徼衢彡犭犰犴犷犸狃狁狎狍狒狨狯狩狲狴狷猁狳猃狺" -- 0xe1
      , "釦釧釨釩釪釫釬釭釮釯釰釱釲釳釴釵釶釷釸釹釺釻釼釽釾釿鈀鈁鈂鈃鈄鈅鈆鈇鈈鈉鈊鈋鈌鈍鈎鈏鈐鈑鈒鈓鈔鈕鈖鈗鈘鈙鈚鈛鈜鈝鈞鈟鈠鈡鈢鈣鈤\0鈥鈦鈧鈨鈩鈪鈫鈬鈭鈮鈯鈰鈱鈲鈳鈴鈵鈶鈷鈸鈹鈺鈻鈼鈽鈾鈿鉀鉁鉂鉃鉄鉅狻猗猓猡猊猞猝猕猢猹猥猬猸猱獐獍獗獠獬獯獾舛夥飧夤夂饣饧饨饩饪饫饬饴饷饽馀馄馇馊馍馐馑馓馔馕庀庑庋庖庥庠庹庵庾庳赓廒廑廛廨廪膺忄忉忖忏怃忮怄忡忤忾怅怆忪忭忸怙怵怦怛怏怍怩怫怊怿怡恸恹恻恺恂" -- 0xe2
      , "鉆鉇鉈鉉鉊鉋鉌鉍鉎鉏鉐鉑鉒鉓鉔鉕鉖鉗鉘鉙鉚鉛鉜鉝鉞鉟鉠鉡鉢鉣鉤鉥鉦鉧鉨鉩鉪鉫鉬鉭鉮鉯鉰鉱鉲鉳鉵鉶鉷鉸鉹鉺鉻鉼鉽鉾鉿銀銁銂銃銄銅\0銆銇銈銉銊銋銌銍銏銐銑銒銓銔銕銖銗銘銙銚銛銜銝銞銟銠銡銢銣銤銥銦銧恪恽悖悚悭悝悃悒悌悛惬悻悱惝惘惆惚悴愠愦愕愣惴愀愎愫慊慵憬憔憧憷懔懵忝隳闩闫闱闳闵闶闼闾阃阄阆阈阊阋阌阍阏阒阕阖阗阙阚丬爿戕氵汔汜汊沣沅沐沔沌汨汩汴汶沆沩泐泔沭泷泸泱泗沲泠泖泺泫泮沱泓泯泾" -- 0xe3
      , "銨銩銪銫銬銭銯銰銱銲銳銴銵銶銷銸銹銺銻銼銽銾銿鋀鋁鋂鋃鋄鋅鋆鋇鋉鋊鋋鋌鋍鋎鋏鋐鋑鋒鋓鋔鋕鋖鋗鋘鋙鋚鋛鋜鋝鋞鋟鋠鋡鋢鋣鋤鋥鋦鋧鋨\0鋩鋪鋫鋬鋭鋮鋯鋰鋱鋲鋳鋴鋵鋶鋷鋸鋹鋺鋻鋼鋽鋾鋿錀錁錂錃錄錅錆錇錈錉洹洧洌浃浈洇洄洙洎洫浍洮洵洚浏浒浔洳涑浯涞涠浞涓涔浜浠浼浣渚淇淅淞渎涿淠渑淦淝淙渖涫渌涮渫湮湎湫溲湟溆湓湔渲渥湄滟溱溘滠漭滢溥溧溽溻溷滗溴滏溏滂溟潢潆潇漤漕滹漯漶潋潴漪漉漩澉澍澌潸潲潼潺濑" -- 0xe4
      , "錊錋錌錍錎錏錐錑錒錓錔錕錖錗錘錙錚錛錜錝錞錟錠錡錢錣錤錥錦錧錨錩錪錫錬錭錮錯錰錱録錳錴錵錶錷錸錹錺錻錼錽錿鍀鍁鍂鍃鍄鍅鍆鍇鍈鍉\0鍊鍋鍌鍍鍎鍏鍐鍑鍒鍓鍔鍕鍖鍗鍘鍙鍚鍛鍜鍝鍞鍟鍠鍡鍢鍣鍤鍥鍦鍧鍨鍩鍫濉澧澹澶濂濡濮濞濠濯瀚瀣瀛瀹瀵灏灞宀宄宕宓宥宸甯骞搴寤寮褰寰蹇謇辶迓迕迥迮迤迩迦迳迨逅逄逋逦逑逍逖逡逵逶逭逯遄遑遒遐遨遘遢遛暹遴遽邂邈邃邋彐彗彖彘尻咫屐屙孱屣屦羼弪弩弭艴弼鬻屮妁妃妍妩妪妣" -- 0xe5
      , "鍬鍭鍮鍯鍰鍱鍲鍳鍴鍵鍶鍷鍸鍹鍺鍻鍼鍽鍾鍿鎀鎁鎂鎃鎄鎅鎆鎇鎈鎉鎊鎋鎌鎍鎎鎐鎑鎒鎓鎔鎕鎖鎗鎘鎙鎚鎛鎜鎝鎞鎟鎠鎡鎢鎣鎤鎥鎦鎧鎨鎩鎪鎫\0鎬鎭鎮鎯鎰鎱鎲鎳鎴鎵鎶鎷鎸鎹鎺鎻鎼鎽鎾鎿鏀鏁鏂鏃鏄鏅鏆鏇鏈鏉鏋鏌鏍妗姊妫妞妤姒妲妯姗妾娅娆姝娈姣姘姹娌娉娲娴娑娣娓婀婧婊婕娼婢婵胬媪媛婷婺媾嫫媲嫒嫔媸嫠嫣嫱嫖嫦嫘嫜嬉嬗嬖嬲嬷孀尕尜孚孥孳孑孓孢驵驷驸驺驿驽骀骁骅骈骊骐骒骓骖骘骛骜骝骟骠骢骣骥骧纟纡纣纥纨纩" -- 0xe6
      , "鏎鏏鏐鏑鏒鏓鏔鏕鏗鏘鏙鏚鏛鏜鏝鏞鏟鏠鏡鏢鏣鏤鏥鏦鏧鏨鏩鏪鏫鏬鏭鏮鏯鏰鏱鏲鏳鏴鏵鏶鏷鏸鏹鏺鏻鏼鏽鏾鏿鐀鐁鐂鐃鐄鐅鐆鐇鐈鐉鐊鐋鐌鐍\0鐎鐏鐐鐑鐒鐓鐔鐕鐖鐗鐘鐙鐚鐛鐜鐝鐞鐟鐠鐡鐢鐣鐤鐥鐦鐧鐨鐩鐪鐫鐬鐭鐮纭纰纾绀绁绂绉绋绌绐绔绗绛绠绡绨绫绮绯绱绲缍绶绺绻绾缁缂缃缇缈缋缌缏缑缒缗缙缜缛缟缡缢缣缤缥缦缧缪缫缬缭缯缰缱缲缳缵幺畿巛甾邕玎玑玮玢玟珏珂珑玷玳珀珉珈珥珙顼琊珩珧珞玺珲琏琪瑛琦琥琨琰琮琬" -- 0xe7
      , "鐯鐰鐱鐲鐳鐴鐵鐶鐷鐸鐹鐺鐻鐼鐽鐿鑀鑁鑂鑃鑄鑅鑆鑇鑈鑉鑊鑋鑌鑍鑎鑏鑐鑑鑒鑓鑔鑕鑖鑗鑘鑙鑚鑛鑜鑝鑞鑟鑠鑡鑢鑣鑤鑥鑦鑧鑨鑩鑪鑬鑭鑮鑯\0鑰鑱鑲鑳鑴鑵鑶鑷鑸鑹鑺鑻鑼鑽鑾鑿钀钁钂钃钄钑钖钘铇铏铓铔铚铦铻锜锠琛琚瑁瑜瑗瑕瑙瑷瑭瑾璜璎璀璁璇璋璞璨璩璐璧瓒璺韪韫韬杌杓杞杈杩枥枇杪杳枘枧杵枨枞枭枋杷杼柰栉柘栊柩枰栌柙枵柚枳柝栀柃枸柢栎柁柽栲栳桠桡桎桢桄桤梃栝桕桦桁桧桀栾桊桉栩梵梏桴桷梓桫棂楮棼椟椠棹" -- 0xe8
      , "锧锳锽镃镈镋镕镚镠镮镴镵長镸镹镺镻镼镽镾門閁閂閃閄閅閆閇閈閉閊開閌閍閎閏閐閑閒間閔閕閖閗閘閙閚閛閜閝閞閟閠閡関閣閤閥閦閧閨閩閪\0閫閬閭閮閯閰閱閲閳閴閵閶閷閸閹閺閻閼閽閾閿闀闁闂闃闄闅闆闇闈闉闊闋椤棰椋椁楗棣椐楱椹楠楂楝榄楫榀榘楸椴槌榇榈槎榉楦楣楹榛榧榻榫榭槔榱槁槊槟榕槠榍槿樯槭樗樘橥槲橄樾檠橐橛樵檎橹樽樨橘橼檑檐檩檗檫猷獒殁殂殇殄殒殓殍殚殛殡殪轫轭轱轲轳轵轶轸轷轹轺轼轾辁辂辄辇辋" -- 0xe9
      , "闌闍闎闏闐闑闒闓闔闕闖闗闘闙闚闛關闝闞闟闠闡闢闣闤闥闦闧闬闿阇阓阘阛阞阠阣阤阥阦阧阨阩阫阬阭阯阰阷阸阹阺阾陁陃陊陎陏陑陒陓陖陗\0陘陙陚陜陝陞陠陣陥陦陫陭陮陯陰陱陳陸陹険陻陼陽陾陿隀隁隂隃隄隇隉隊辍辎辏辘辚軎戋戗戛戟戢戡戥戤戬臧瓯瓴瓿甏甑甓攴旮旯旰昊昙杲昃昕昀炅曷昝昴昱昶昵耆晟晔晁晏晖晡晗晷暄暌暧暝暾曛曜曦曩贲贳贶贻贽赀赅赆赈赉赇赍赕赙觇觊觋觌觎觏觐觑牮犟牝牦牯牾牿犄犋犍犏犒挈挲掰" -- 0xea
      , "隌階隑隒隓隕隖隚際隝隞隟隠隡隢隣隤隥隦隨隩險隫隬隭隮隯隱隲隴隵隷隸隺隻隿雂雃雈雊雋雐雑雓雔雖雗雘雙雚雛雜雝雞雟雡離難雤雥雦雧雫\0雬雭雮雰雱雲雴雵雸雺電雼雽雿霂霃霅霊霋霌霐霑霒霔霕霗霘霙霚霛霝霟霠搿擘耄毪毳毽毵毹氅氇氆氍氕氘氙氚氡氩氤氪氲攵敕敫牍牒牖爰虢刖肟肜肓肼朊肽肱肫肭肴肷胧胨胩胪胛胂胄胙胍胗朐胝胫胱胴胭脍脎胲胼朕脒豚脶脞脬脘脲腈腌腓腴腙腚腱腠腩腼腽腭腧塍媵膈膂膑滕膣膪臌朦臊膻" -- 0xeb
      , "霡霢霣霤霥霦霧霨霩霫霬霮霯霱霳霴霵霶霷霺霻霼霽霿靀靁靂靃靄靅靆靇靈靉靊靋靌靍靎靏靐靑靔靕靗靘靚靜靝靟靣靤靦靧靨靪靫靬靭靮靯靰靱\0靲靵靷靸靹靺靻靽靾靿鞀鞁鞂鞃鞄鞆鞇鞈鞉鞊鞌鞎鞏鞐鞓鞕鞖鞗鞙鞚鞛鞜鞝臁膦欤欷欹歃歆歙飑飒飓飕飙飚殳彀毂觳斐齑斓於旆旄旃旌旎旒旖炀炜炖炝炻烀炷炫炱烨烊焐焓焖焯焱煳煜煨煅煲煊煸煺熘熳熵熨熠燠燔燧燹爝爨灬焘煦熹戾戽扃扈扉礻祀祆祉祛祜祓祚祢祗祠祯祧祺禅禊禚禧禳忑忐" -- 0xec
      , "鞞鞟鞡鞢鞤鞥鞦鞧鞨鞩鞪鞬鞮鞰鞱鞳鞵鞶鞷鞸鞹鞺鞻鞼鞽鞾鞿韀韁韂韃韄韅韆韇韈韉韊韋韌韍韎韏韐韑韒韓韔韕韖韗韘韙韚韛韜韝韞韟韠韡韢韣\0韤韥韨韮韯韰韱韲韴韷韸韹韺韻韼韽韾響頀頁頂頃頄項順頇須頉頊頋頌頍頎怼恝恚恧恁恙恣悫愆愍慝憩憝懋懑戆肀聿沓泶淼矶矸砀砉砗砘砑斫砭砜砝砹砺砻砟砼砥砬砣砩硎硭硖硗砦硐硇硌硪碛碓碚碇碜碡碣碲碹碥磔磙磉磬磲礅磴礓礤礞礴龛黹黻黼盱眄眍盹眇眈眚眢眙眭眦眵眸睐睑睇睃睚睨" -- 0xed
      , "頏預頑頒頓頔頕頖頗領頙頚頛頜頝頞頟頠頡頢頣頤頥頦頧頨頩頪頫頬頭頮頯頰頱頲頳頴頵頶頷頸頹頺頻頼頽頾頿顀顁顂顃顄顅顆顇顈顉顊顋題額\0顎顏顐顑顒顓顔顕顖顗願顙顚顛顜顝類顟顠顡顢顣顤顥顦顧顨顩顪顫顬顭顮睢睥睿瞍睽瞀瞌瞑瞟瞠瞰瞵瞽町畀畎畋畈畛畲畹疃罘罡罟詈罨罴罱罹羁罾盍盥蠲钅钆钇钋钊钌钍钏钐钔钗钕钚钛钜钣钤钫钪钭钬钯钰钲钴钶钷钸钹钺钼钽钿铄铈铉铊铋铌铍铎铐铑铒铕铖铗铙铘铛铞铟铠铢铤铥铧铨铪" -- 0xee
      , "顯顰顱顲顳顴颋颎颒颕颙颣風颩颪颫颬颭颮颯颰颱颲颳颴颵颶颷颸颹颺颻颼颽颾颿飀飁飂飃飄飅飆飇飈飉飊飋飌飍飏飐飔飖飗飛飜飝飠飡飢飣飤\0飥飦飩飪飫飬飭飮飯飰飱飲飳飴飵飶飷飸飹飺飻飼飽飾飿餀餁餂餃餄餅餆餇铩铫铮铯铳铴铵铷铹铼铽铿锃锂锆锇锉锊锍锎锏锒锓锔锕锖锘锛锝锞锟锢锪锫锩锬锱锲锴锶锷锸锼锾锿镂锵镄镅镆镉镌镎镏镒镓镔镖镗镘镙镛镞镟镝镡镢镤镥镦镧镨镩镪镫镬镯镱镲镳锺矧矬雉秕秭秣秫稆嵇稃稂稞稔" -- 0xef
      , "餈餉養餋餌餎餏餑餒餓餔餕餖餗餘餙餚餛餜餝餞餟餠餡餢餣餤餥餦餧館餩餪餫餬餭餯餰餱餲餳餴餵餶餷餸餹餺餻餼餽餾餿饀饁饂饃饄饅饆饇饈饉\0饊饋饌饍饎饏饐饑饒饓饖饗饘饙饚饛饜饝饞饟饠饡饢饤饦饳饸饹饻饾馂馃馉稹稷穑黏馥穰皈皎皓皙皤瓞瓠甬鸠鸢鸨鸩鸪鸫鸬鸲鸱鸶鸸鸷鸹鸺鸾鹁鹂鹄鹆鹇鹈鹉鹋鹌鹎鹑鹕鹗鹚鹛鹜鹞鹣鹦鹧鹨鹩鹪鹫鹬鹱鹭鹳疒疔疖疠疝疬疣疳疴疸痄疱疰痃痂痖痍痣痨痦痤痫痧瘃痱痼痿瘐瘀瘅瘌瘗瘊瘥瘘瘕瘙" -- 0xf0
      , "馌馎馚馛馜馝馞馟馠馡馢馣馤馦馧馩馪馫馬馭馮馯馰馱馲馳馴馵馶馷馸馹馺馻馼馽馾馿駀駁駂駃駄駅駆駇駈駉駊駋駌駍駎駏駐駑駒駓駔駕駖駗駘\0駙駚駛駜駝駞駟駠駡駢駣駤駥駦駧駨駩駪駫駬駭駮駯駰駱駲駳駴駵駶駷駸駹瘛瘼瘢瘠癀瘭瘰瘿瘵癃瘾瘳癍癞癔癜癖癫癯翊竦穸穹窀窆窈窕窦窠窬窨窭窳衤衩衲衽衿袂袢裆袷袼裉裢裎裣裥裱褚裼裨裾裰褡褙褓褛褊褴褫褶襁襦襻疋胥皲皴矜耒耔耖耜耠耢耥耦耧耩耨耱耋耵聃聆聍聒聩聱覃顸颀颃" -- 0xf1
      , "駺駻駼駽駾駿騀騁騂騃騄騅騆騇騈騉騊騋騌騍騎騏騐騑騒験騔騕騖騗騘騙騚騛騜騝騞騟騠騡騢騣騤騥騦騧騨騩騪騫騬騭騮騯騰騱騲騳騴騵騶騷騸\0騹騺騻騼騽騾騿驀驁驂驃驄驅驆驇驈驉驊驋驌驍驎驏驐驑驒驓驔驕驖驗驘驙颉颌颍颏颔颚颛颞颟颡颢颥颦虍虔虬虮虿虺虼虻蚨蚍蚋蚬蚝蚧蚣蚪蚓蚩蚶蛄蚵蛎蚰蚺蚱蚯蛉蛏蚴蛩蛱蛲蛭蛳蛐蜓蛞蛴蛟蛘蛑蜃蜇蛸蜈蜊蜍蜉蜣蜻蜞蜥蜮蜚蜾蝈蜴蜱蜩蜷蜿螂蜢蝽蝾蝻蝠蝰蝌蝮螋蝓蝣蝼蝤蝙蝥螓螯螨蟒" -- 0xf2
      , "驚驛驜驝驞驟驠驡驢驣驤驥驦驧驨驩驪驫驲骃骉骍骎骔骕骙骦骩骪骫骬骭骮骯骲骳骴骵骹骻骽骾骿髃髄髆髇髈髉髊髍髎髏髐髒體髕髖髗髙髚髛髜\0髝髞髠髢髣髤髥髧髨髩髪髬髮髰髱髲髳髴髵髶髷髸髺髼髽髾髿鬀鬁鬂鬄鬅鬆蟆螈螅螭螗螃螫蟥螬螵螳蟋蟓螽蟑蟀蟊蟛蟪蟠蟮蠖蠓蟾蠊蠛蠡蠹蠼缶罂罄罅舐竺竽笈笃笄笕笊笫笏筇笸笪笙笮笱笠笥笤笳笾笞筘筚筅筵筌筝筠筮筻筢筲筱箐箦箧箸箬箝箨箅箪箜箢箫箴篑篁篌篝篚篥篦篪簌篾篼簏簖簋" -- 0xf3
      , "鬇鬉鬊鬋鬌鬍鬎鬐鬑鬒鬔鬕鬖鬗鬘鬙鬚鬛鬜鬝鬞鬠鬡鬢鬤鬥鬦鬧鬨鬩鬪鬫鬬鬭鬮鬰鬱鬳鬴鬵鬶鬷鬸鬹鬺鬽鬾鬿魀魆魊魋魌魎魐魒魓魕魖魗魘魙魚\0魛魜魝魞魟魠魡魢魣魤魥魦魧魨魩魪魫魬魭魮魯魰魱魲魳魴魵魶魷魸魹魺魻簟簪簦簸籁籀臾舁舂舄臬衄舡舢舣舭舯舨舫舸舻舳舴舾艄艉艋艏艚艟艨衾袅袈裘裟襞羝羟羧羯羰羲籼敉粑粝粜粞粢粲粼粽糁糇糌糍糈糅糗糨艮暨羿翎翕翥翡翦翩翮翳糸絷綦綮繇纛麸麴赳趄趔趑趱赧赭豇豉酊酐酎酏酤" -- 0xf4
      , "魼魽魾魿鮀鮁鮂鮃鮄鮅鮆鮇鮈鮉鮊鮋鮌鮍鮎鮏鮐鮑鮒鮓鮔鮕鮖鮗鮘鮙鮚鮛鮜鮝鮞鮟鮠鮡鮢鮣鮤鮥鮦鮧鮨鮩鮪鮫鮬鮭鮮鮯鮰鮱鮲鮳鮴鮵鮶鮷鮸鮹鮺\0鮻鮼鮽鮾鮿鯀鯁鯂鯃鯄鯅鯆鯇鯈鯉鯊鯋鯌鯍鯎鯏鯐鯑鯒鯓鯔鯕鯖鯗鯘鯙鯚鯛酢酡酰酩酯酽酾酲酴酹醌醅醐醍醑醢醣醪醭醮醯醵醴醺豕鹾趸跫踅蹙蹩趵趿趼趺跄跖跗跚跞跎跏跛跆跬跷跸跣跹跻跤踉跽踔踝踟踬踮踣踯踺蹀踹踵踽踱蹉蹁蹂蹑蹒蹊蹰蹶蹼蹯蹴躅躏躔躐躜躞豸貂貊貅貘貔斛觖觞觚觜" -- 0xf5
      , "鯜鯝鯞鯟鯠鯡鯢鯣鯤鯥鯦鯧鯨鯩鯪鯫鯬鯭鯮鯯鯰鯱鯲鯳鯴鯵鯶鯷鯸鯹鯺鯻鯼鯽鯾鯿鰀鰁鰂鰃鰄鰅鰆鰇鰈鰉鰊鰋鰌鰍鰎鰏鰐鰑鰒鰓鰔鰕鰖鰗鰘鰙鰚\0鰛鰜鰝鰞鰟鰠鰡鰢鰣鰤鰥鰦鰧鰨鰩鰪鰫鰬鰭鰮鰯鰰鰱鰲鰳鰴鰵鰶鰷鰸鰹鰺鰻觥觫觯訾謦靓雩雳雯霆霁霈霏霎霪霭霰霾龀龃龅龆龇龈龉龊龌黾鼋鼍隹隼隽雎雒瞿雠銎銮鋈錾鍪鏊鎏鐾鑫鱿鲂鲅鲆鲇鲈稣鲋鲎鲐鲑鲒鲔鲕鲚鲛鲞鲟鲠鲡鲢鲣鲥鲦鲧鲨鲩鲫鲭鲮鲰鲱鲲鲳鲴鲵鲶鲷鲺鲻鲼鲽鳄鳅鳆鳇鳊鳋" -- 0xf6
      , "鰼鰽鰾鰿鱀鱁鱂鱃鱄鱅鱆鱇鱈鱉鱊鱋鱌鱍鱎鱏鱐鱑鱒鱓鱔鱕鱖鱗鱘鱙鱚鱛鱜鱝鱞鱟鱠鱡鱢鱣鱤鱥鱦鱧鱨鱩鱪鱫鱬鱭鱮鱯鱰鱱鱲鱳鱴鱵鱶鱷鱸鱹鱺\0鱻鱽鱾鲀鲃鲄鲉鲊鲌鲏鲓鲖鲗鲘鲙鲝鲪鲬鲯鲹鲾鲿鳀鳁鳂鳈鳉鳑鳒鳚鳛鳠鳡鳌鳍鳎鳏鳐鳓鳔鳕鳗鳘鳙鳜鳝鳟鳢靼鞅鞑鞒鞔鞯鞫鞣鞲鞴骱骰骷鹘骶骺骼髁髀髅髂髋髌髑魅魃魇魉魈魍魑飨餍餮饕饔髟髡髦髯髫髻髭髹鬈鬏鬓鬟鬣麽麾縻麂麇麈麋麒鏖麝麟黛黜黝黠黟黢黩黧黥黪黯鼢鼬鼯鼹鼷鼽鼾齄" -- 0xf7
      , "鳣鳤鳥鳦鳧鳨鳩鳪鳫鳬鳭鳮鳯鳰鳱鳲鳳鳴鳵鳶鳷鳸鳹鳺鳻鳼鳽鳾鳿鴀鴁鴂鴃鴄鴅鴆鴇鴈鴉鴊鴋鴌鴍鴎鴏鴐鴑鴒鴓鴔鴕鴖鴗鴘鴙鴚鴛鴜鴝鴞鴟鴠鴡\0鴢鴣鴤鴥鴦鴧鴨鴩鴪鴫鴬鴭鴮鴯鴰鴱鴲鴳鴴鴵鴶鴷鴸鴹鴺鴻鴼鴽鴾鴿鵀鵁鵂\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xf8
      , "鵃鵄鵅鵆鵇鵈鵉鵊鵋鵌鵍鵎鵏鵐鵑鵒鵓鵔鵕鵖鵗鵘鵙鵚鵛鵜鵝鵞鵟鵠鵡鵢鵣鵤鵥鵦鵧鵨鵩鵪鵫鵬鵭鵮鵯鵰鵱鵲鵳鵴鵵鵶鵷鵸鵹鵺鵻鵼鵽鵾鵿鶀鶁\0鶂鶃鶄鶅鶆鶇鶈鶉鶊鶋鶌鶍鶎鶏鶐鶑鶒鶓鶔鶕鶖鶗鶘鶙鶚鶛鶜鶝鶞鶟鶠鶡鶢\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xf9
      , "鶣鶤鶥鶦鶧鶨鶩鶪鶫鶬鶭鶮鶯鶰鶱鶲鶳鶴鶵鶶鶷鶸鶹鶺鶻鶼鶽鶾鶿鷀鷁鷂鷃鷄鷅鷆鷇鷈鷉鷊鷋鷌鷍鷎鷏鷐鷑鷒鷓鷔鷕鷖鷗鷘鷙鷚鷛鷜鷝鷞鷟鷠鷡\0鷢鷣鷤鷥鷦鷧鷨鷩鷪鷫鷬鷭鷮鷯鷰鷱鷲鷳鷴鷵鷶鷷鷸鷹鷺鷻鷼鷽鷾鷿鸀鸁鸂\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xfa
      , "鸃鸄鸅鸆鸇鸈鸉鸊鸋鸌鸍鸎鸏鸐鸑鸒鸓鸔鸕鸖鸗鸘鸙鸚鸛鸜鸝鸞鸤鸧鸮鸰鸴鸻鸼鹀鹍鹐鹒鹓鹔鹖鹙鹝鹟鹠鹡鹢鹥鹮鹯鹲鹴鹵鹶鹷鹸鹹鹺鹻鹼鹽麀\0麁麃麄麅麆麉麊麌麍麎麏麐麑麔麕麖麗麘麙麚麛麜麞麠麡麢麣麤麥麧麨麩麪\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xfb
      , "麫麬麭麮麯麰麱麲麳麵麶麷麹麺麼麿黀黁黂黃黅黆黇黈黊黋黌黐黒黓黕黖黗黙黚點黡黣黤黦黨黫黬黭黮黰黱黲黳黴黵黶黷黸黺黽黿鼀鼁鼂鼃鼄鼅\0鼆鼇鼈鼉鼊鼌鼏鼑鼒鼔鼕鼖鼘鼚鼛鼜鼝鼞鼟鼡鼣鼤鼥鼦鼧鼨鼩鼪鼫鼭鼮鼰鼱\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xfc
      , "鼲鼳鼴鼵鼶鼸鼺鼼鼿齀齁齂齃齅齆齇齈齉齊齋齌齍齎齏齒齓齔齕齖齗齘齙齚齛齜齝齞齟齠齡齢齣齤齥齦齧齨齩齪齫齬齭齮齯齰齱齲齳齴齵齶齷齸\0齹齺齻齼齽齾龁龂龍龎龏龐龑龒龓龔龕龖龗龘龜龝龞龡龢龣龤龥郎凉秊裏隣\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xfd
      , "兀嗀﨎﨏﨑﨓﨔礼﨟蘒﨡﨣﨤﨧﨨﨩\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xfe
      ]
  }

-- | Traditional Chinese (Big5).  0 single-byte and 13752 double-byte mappings.
cp950Table :: Codepage
cp950Table = Codepage
  { cpName = "cp950"
  , cpLeadLo = 0xa1
  , cpLeadHi = 0xf9
  , cpTrailLo = 0x40
  , cpTrailHi = 0xfe
  , cpSingle = U.listArray (0, 127) "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0"
  , cpDouble = U.listArray (0, 16998) $ concat
      [ "\12288，、。．‧；：？！︰…‥﹐﹑﹒·﹔﹕﹖﹗｜–︱—︳╴︴﹏（）︵︶｛｝︷︸〔〕︹︺【】︻︼《》︽︾〈〉︿﹀「」﹁﹂『』﹃﹄﹙﹚\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0﹛﹜﹝﹞‘’“”〝〞‵′＃＆＊※§〃○●△▲◎☆★◇◆□■▽▼㊣℅¯￣＿ˍ﹉﹊﹍﹎﹋﹌﹟﹠﹡＋－×÷±√＜＞＝≦≧≠∞≒≡﹢﹣﹤﹥﹦～∩∪⊥∠∟⊿㏒㏑∫∮∵∴♀♂⊕⊙↑↓←→↖↗↙↘∥∣／" -- 0xa1
      , "＼∕﹨＄￥〒￠￡％＠℃℉﹩﹪﹫㏕㎜㎝㎞㏎㎡㎎㎏㏄°兙兛兞兝兡兣嗧瓩糎▁▂▃▄▅▆▇█▏▎▍▌▋▊▉┼┴┬┤├▔─│▕┌┐└┘╭\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0╮╰╯═╞╪╡◢◣◥◤╱╲╳０１２３４５６７８９ⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩ〡〢〣〤〥〦〧〨〩十卄卅ＡＢＣＤＥＦＧＨＩＪＫＬＭＮＯＰＱＲＳＴＵＶＷＸＹＺａｂｃｄｅｆｇｈｉｊｋｌｍｎｏｐｑｒｓｔｕｖ" -- 0xa2
      , "ｗｘｙｚΑΒΓΔΕΖΗΘΙΚΛΜΝΞΟΠΡΣΤΥΦΧΨΩαβγδεζηθικλμνξοπρστυφχψωㄅㄆㄇㄈㄉㄊㄋㄌㄍㄎㄏ\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0ㄐㄑㄒㄓㄔㄕㄖㄗㄘㄙㄚㄛㄜㄝㄞㄟㄠㄡㄢㄣㄤㄥㄦㄧㄨㄩ˙ˉˊˇˋ\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0€\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xa3
      , "一乙丁七乃九了二人儿入八几刀刁力匕十卜又三下丈上丫丸凡久么也乞于亡兀刃勺千叉口土士夕大女子孑孓寸小尢尸山川工己已巳巾干廾弋弓才\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0丑丐不中丰丹之尹予云井互五亢仁什仃仆仇仍今介仄元允內六兮公冗凶分切刈勻勾勿化匹午升卅卞厄友及反壬天夫太夭孔少尤尺屯巴幻廿弔引心戈戶手扎支文斗斤方日曰月木欠止歹毋比毛氏水火爪父爻片牙牛犬王丙" -- 0xa4
      , "世丕且丘主乍乏乎以付仔仕他仗代令仙仞充兄冉冊冬凹出凸刊加功包匆北匝仟半卉卡占卯卮去可古右召叮叩叨叼司叵叫另只史叱台句叭叻四囚外\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0央失奴奶孕它尼巨巧左市布平幼弁弘弗必戊打扔扒扑斥旦朮本未末札正母民氐永汁汀氾犯玄玉瓜瓦甘生用甩田由甲申疋白皮皿目矛矢石示禾穴立丞丟乒乓乩亙交亦亥仿伉伙伊伕伍伐休伏仲件任仰仳份企伋光兇兆先全" -- 0xa5
      , "共再冰列刑划刎刖劣匈匡匠印危吉吏同吊吐吁吋各向名合吃后吆吒因回囝圳地在圭圬圯圩夙多夷夸妄奸妃好她如妁字存宇守宅安寺尖屹州帆并年\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0式弛忙忖戎戌戍成扣扛托收早旨旬旭曲曳有朽朴朱朵次此死氖汝汗汙江池汐汕污汛汍汎灰牟牝百竹米糸缶羊羽老考而耒耳聿肉肋肌臣自至臼舌舛舟艮色艾虫血行衣西阡串亨位住佇佗佞伴佛何估佐佑伽伺伸佃佔似但佣" -- 0xa6
      , "作你伯低伶余佝佈佚兌克免兵冶冷別判利刪刨劫助努劬匣即卵吝吭吞吾否呎吧呆呃吳呈呂君吩告吹吻吸吮吵吶吠吼呀吱含吟听囪困囤囫坊坑址坍\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0均坎圾坐坏圻壯夾妝妒妨妞妣妙妖妍妤妓妊妥孝孜孚孛完宋宏尬局屁尿尾岐岑岔岌巫希序庇床廷弄弟彤形彷役忘忌志忍忱快忸忪戒我抄抗抖技扶抉扭把扼找批扳抒扯折扮投抓抑抆改攻攸旱更束李杏材村杜杖杞杉杆杠" -- 0xa7
      , "杓杗步每求汞沙沁沈沉沅沛汪決沐汰沌汨沖沒汽沃汲汾汴沆汶沍沔沘沂灶灼災灸牢牡牠狄狂玖甬甫男甸皂盯矣私秀禿究系罕肖肓肝肘肛肚育良芒\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0芋芍見角言谷豆豕貝赤走足身車辛辰迂迆迅迄巡邑邢邪邦那酉釆里防阮阱阪阬並乖乳事些亞享京佯依侍佳使佬供例來侃佰併侈佩佻侖佾侏侑佺兔兒兕兩具其典冽函刻券刷刺到刮制剁劾劻卒協卓卑卦卷卸卹取叔受味呵" -- 0xa8
      , "咖呸咕咀呻呷咄咒咆呼咐呱呶和咚呢周咋命咎固垃坷坪坩坡坦坤坼夜奉奇奈奄奔妾妻委妹妮姑姆姐姍始姓姊妯妳姒姅孟孤季宗定官宜宙宛尚屈居\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0屆岷岡岸岩岫岱岳帘帚帖帕帛帑幸庚店府底庖延弦弧弩往征彿彼忝忠忽念忿怏怔怯怵怖怪怕怡性怩怫怛或戕房戾所承拉拌拄抿拂抹拒招披拓拔拋拈抨抽押拐拙拇拍抵拚抱拘拖拗拆抬拎放斧於旺昔易昌昆昂明昀昏昕昊" -- 0xa9
      , "昇服朋杭枋枕東果杳杷枇枝林杯杰板枉松析杵枚枓杼杪杲欣武歧歿氓氛泣注泳沱泌泥河沽沾沼波沫法泓沸泄油況沮泗泅泱沿治泡泛泊沬泯泜泖泠\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0炕炎炒炊炙爬爭爸版牧物狀狎狙狗狐玩玨玟玫玥甽疝疙疚的盂盲直知矽社祀祁秉秈空穹竺糾罔羌羋者肺肥肢肱股肫肩肴肪肯臥臾舍芳芝芙芭芽芟芹花芬芥芯芸芣芰芾芷虎虱初表軋迎返近邵邸邱邶采金長門阜陀阿阻附" -- 0xaa
      , "陂隹雨青非亟亭亮信侵侯便俠俑俏保促侶俘俟俊俗侮俐俄係俚俎俞侷兗冒冑冠剎剃削前剌剋則勇勉勃勁匍南卻厚叛咬哀咨哎哉咸咦咳哇哂咽咪品\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0哄哈咯咫咱咻咩咧咿囿垂型垠垣垢城垮垓奕契奏奎奐姜姘姿姣姨娃姥姪姚姦威姻孩宣宦室客宥封屎屏屍屋峙峒巷帝帥帟幽庠度建弈弭彥很待徊律徇後徉怒思怠急怎怨恍恰恨恢恆恃恬恫恪恤扁拜挖按拼拭持拮拽指拱拷" -- 0xab
      , "拯括拾拴挑挂政故斫施既春昭映昧是星昨昱昤曷柿染柱柔某柬架枯柵柩柯柄柑枴柚查枸柏柞柳枰柙柢柝柒歪殃殆段毒毗氟泉洋洲洪流津洌洱洞洗\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0活洽派洶洛泵洹洧洸洩洮洵洎洫炫為炳炬炯炭炸炮炤爰牲牯牴狩狠狡玷珊玻玲珍珀玳甚甭畏界畎畋疫疤疥疢疣癸皆皇皈盈盆盃盅省盹相眉看盾盼眇矜砂研砌砍祆祉祈祇禹禺科秒秋穿突竿竽籽紂紅紀紉紇約紆缸美羿耄" -- 0xac
      , "耐耍耑耶胖胥胚胃胄背胡胛胎胞胤胝致舢苧范茅苣苛苦茄若茂茉苒苗英茁苜苔苑苞苓苟苯茆虐虹虻虺衍衫要觔計訂訃貞負赴赳趴軍軌述迦迢迪迥\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0迭迫迤迨郊郎郁郃酋酊重閂限陋陌降面革韋韭音頁風飛食首香乘亳倌倍倣俯倦倥俸倩倖倆值借倚倒們俺倀倔倨俱倡個候倘俳修倭倪俾倫倉兼冤冥冢凍凌准凋剖剜剔剛剝匪卿原厝叟哨唐唁唷哼哥哲唆哺唔哩哭員唉哮哪" -- 0xad
      , "哦唧唇哽唏圃圄埂埔埋埃堉夏套奘奚娑娘娜娟娛娓姬娠娣娩娥娌娉孫屘宰害家宴宮宵容宸射屑展屐峭峽峻峪峨峰島崁峴差席師庫庭座弱徒徑徐恙\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0恣恥恐恕恭恩息悄悟悚悍悔悌悅悖扇拳挈拿捎挾振捕捂捆捏捉挺捐挽挪挫挨捍捌效敉料旁旅時晉晏晃晒晌晅晁書朔朕朗校核案框桓根桂桔栩梳栗桌桑栽柴桐桀格桃株桅栓栘桁殊殉殷氣氧氨氦氤泰浪涕消涇浦浸海浙涓" -- 0xae
      , "浬涉浮浚浴浩涌涊浹涅浥涔烊烘烤烙烈烏爹特狼狹狽狸狷玆班琉珮珠珪珞畔畝畜畚留疾病症疲疳疽疼疹痂疸皋皰益盍盎眩真眠眨矩砰砧砸砝破砷\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0砥砭砠砟砲祕祐祠祟祖神祝祗祚秤秣秧租秦秩秘窄窈站笆笑粉紡紗紋紊素索純紐紕級紜納紙紛缺罟羔翅翁耆耘耕耙耗耽耿胱脂胰脅胭胴脆胸胳脈能脊胼胯臭臬舀舐航舫舨般芻茫荒荔荊茸荐草茵茴荏茲茹茶茗荀茱茨荃" -- 0xaf
      , "虔蚊蚪蚓蚤蚩蚌蚣蚜衰衷袁袂衽衹記訐討訌訕訊託訓訖訏訑豈豺豹財貢起躬軒軔軏辱送逆迷退迺迴逃追逅迸邕郡郝郢酒配酌釘針釗釜釙閃院陣陡\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0陛陝除陘陞隻飢馬骨高鬥鬲鬼乾偺偽停假偃偌做偉健偶偎偕偵側偷偏倏偯偭兜冕凰剪副勒務勘動匐匏匙匿區匾參曼商啪啦啄啞啡啃啊唱啖問啕唯啤唸售啜唬啣唳啁啗圈國圉域堅堊堆埠埤基堂堵執培夠奢娶婁婉婦婪婀" -- 0xb0
      , "娼婢婚婆婊孰寇寅寄寂宿密尉專將屠屜屝崇崆崎崛崖崢崑崩崔崙崤崧崗巢常帶帳帷康庸庶庵庾張強彗彬彩彫得徙從徘御徠徜恿患悉悠您惋悴惦悽\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0情悻悵惜悼惘惕惆惟悸惚惇戚戛扈掠控捲掖探接捷捧掘措捱掩掉掃掛捫推掄授掙採掬排掏掀捻捩捨捺敝敖救教敗啟敏敘敕敔斜斛斬族旋旌旎晝晚晤晨晦晞曹勗望梁梯梢梓梵桿桶梱梧梗械梃棄梭梆梅梔條梨梟梡梂欲殺" -- 0xb1
      , "毫毬氫涎涼淳淙液淡淌淤添淺清淇淋涯淑涮淞淹涸混淵淅淒渚涵淚淫淘淪深淮淨淆淄涪淬涿淦烹焉焊烽烯爽牽犁猜猛猖猓猙率琅琊球理現琍瓠瓶\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0瓷甜產略畦畢異疏痔痕疵痊痍皎盔盒盛眷眾眼眶眸眺硫硃硎祥票祭移窒窕笠笨笛第符笙笞笮粒粗粕絆絃統紮紹紼絀細紳組累終紲紱缽羞羚翌翎習耜聊聆脯脖脣脫脩脰脤舂舵舷舶船莎莞莘荸莢莖莽莫莒莊莓莉莠荷荻荼" -- 0xb2
      , "莆莧處彪蛇蛀蚶蛄蚵蛆蛋蚱蚯蛉術袞袈被袒袖袍袋覓規訪訝訣訥許設訟訛訢豉豚販責貫貨貪貧赧赦趾趺軛軟這逍通逗連速逝逐逕逞造透逢逖逛途\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0部郭都酗野釵釦釣釧釭釩閉陪陵陳陸陰陴陶陷陬雀雪雩章竟頂頃魚鳥鹵鹿麥麻傢傍傅備傑傀傖傘傚最凱割剴創剩勞勝勛博厥啻喀喧啼喊喝喘喂喜喪喔喇喋喃喳單喟唾喲喚喻喬喱啾喉喫喙圍堯堪場堤堰報堡堝堠壹壺奠" -- 0xb3
      , "婷媚婿媒媛媧孳孱寒富寓寐尊尋就嵌嵐崴嵇巽幅帽幀幃幾廊廁廂廄弼彭復循徨惑惡悲悶惠愜愣惺愕惰惻惴慨惱愎惶愉愀愒戟扉掣掌描揀揩揉揆揍\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0插揣提握揖揭揮捶援揪換摒揚揹敞敦敢散斑斐斯普晰晴晶景暑智晾晷曾替期朝棺棕棠棘棗椅棟棵森棧棹棒棲棣棋棍植椒椎棉棚楮棻款欺欽殘殖殼毯氮氯氬港游湔渡渲湧湊渠渥渣減湛湘渤湖湮渭渦湯渴湍渺測湃渝渾滋" -- 0xb4
      , "溉渙湎湣湄湲湩湟焙焚焦焰無然煮焜牌犄犀猶猥猴猩琺琪琳琢琥琵琶琴琯琛琦琨甥甦畫番痢痛痣痙痘痞痠登發皖皓皴盜睏短硝硬硯稍稈程稅稀窘\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0窗窖童竣等策筆筐筒答筍筋筏筑粟粥絞結絨絕紫絮絲絡給絢絰絳善翔翕耋聒肅腕腔腋腑腎脹腆脾腌腓腴舒舜菩萃菸萍菠菅萋菁華菱菴著萊菰萌菌菽菲菊萸萎萄菜萇菔菟虛蛟蛙蛭蛔蛛蛤蛐蛞街裁裂袱覃視註詠評詞証詁" -- 0xb5
      , "詔詛詐詆訴診訶詖象貂貯貼貳貽賁費賀貴買貶貿貸越超趁跎距跋跚跑跌跛跆軻軸軼辜逮逵週逸進逶鄂郵鄉郾酣酥量鈔鈕鈣鈉鈞鈍鈐鈇鈑閔閏開閑\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0間閒閎隊階隋陽隅隆隍陲隄雁雅雄集雇雯雲韌項順須飧飪飯飩飲飭馮馭黃黍黑亂傭債傲傳僅傾催傷傻傯僇剿剷剽募勦勤勢勣匯嗟嗨嗓嗦嗎嗜嗇嗑嗣嗤嗯嗚嗡嗅嗆嗥嗉園圓塞塑塘塗塚塔填塌塭塊塢塒塋奧嫁嫉嫌媾媽媼" -- 0xb6
      , "媳嫂媲嵩嵯幌幹廉廈弒彙徬微愚意慈感想愛惹愁愈慎慌慄慍愾愴愧愍愆愷戡戢搓搾搞搪搭搽搬搏搜搔損搶搖搗搆敬斟新暗暉暇暈暖暄暘暍會榔業\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0楚楷楠楔極椰概楊楨楫楞楓楹榆楝楣楛歇歲毀殿毓毽溢溯滓溶滂源溝滇滅溥溘溼溺溫滑準溜滄滔溪溧溴煎煙煩煤煉照煜煬煦煌煥煞煆煨煖爺牒猷獅猿猾瑯瑚瑕瑟瑞瑁琿瑙瑛瑜當畸瘀痰瘁痲痱痺痿痴痳盞盟睛睫睦睞督" -- 0xb7
      , "睹睪睬睜睥睨睢矮碎碰碗碘碌碉硼碑碓硿祺祿禁萬禽稜稚稠稔稟稞窟窠筷節筠筮筧粱粳粵經絹綑綁綏絛置罩罪署義羨群聖聘肆肄腱腰腸腥腮腳腫\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0腹腺腦舅艇蒂葷落萱葵葦葫葉葬葛萼萵葡董葩葭葆虞虜號蛹蜓蜈蜇蜀蛾蛻蜂蜃蜆蜊衙裟裔裙補裘裝裡裊裕裒覜解詫該詳試詩詰誇詼詣誠話誅詭詢詮詬詹詻訾詨豢貊貉賊資賈賄貲賃賂賅跡跟跨路跳跺跪跤跦躲較載軾輊" -- 0xb8
      , "辟農運遊道遂達逼違遐遇遏過遍遑逾遁鄒鄗酬酪酩釉鈷鉗鈸鈽鉀鈾鉛鉋鉤鉑鈴鉉鉍鉅鈹鈿鉚閘隘隔隕雍雋雉雊雷電雹零靖靴靶預頑頓頊頒頌飼飴\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0飽飾馳馱馴髡鳩麂鼎鼓鼠僧僮僥僖僭僚僕像僑僱僎僩兢凳劃劂匱厭嗾嘀嘛嘗嗽嘔嘆嘉嘍嘎嗷嘖嘟嘈嘐嗶團圖塵塾境墓墊塹墅塽壽夥夢夤奪奩嫡嫦嫩嫗嫖嫘嫣孵寞寧寡寥實寨寢寤察對屢嶄嶇幛幣幕幗幔廓廖弊彆彰徹慇" -- 0xb9
      , "愿態慷慢慣慟慚慘慵截撇摘摔撤摸摟摺摑摧搴摭摻敲斡旗旖暢暨暝榜榨榕槁榮槓構榛榷榻榫榴槐槍榭槌榦槃榣歉歌氳漳演滾漓滴漩漾漠漬漏漂漢\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0滿滯漆漱漸漲漣漕漫漯澈漪滬漁滲滌滷熔熙煽熊熄熒爾犒犖獄獐瑤瑣瑪瑰瑭甄疑瘧瘍瘋瘉瘓盡監瞄睽睿睡磁碟碧碳碩碣禎福禍種稱窪窩竭端管箕箋筵算箝箔箏箸箇箄粹粽精綻綰綜綽綾綠緊綴網綱綺綢綿綵綸維緒緇綬" -- 0xba
      , "罰翠翡翟聞聚肇腐膀膏膈膊腿膂臧臺與舔舞艋蓉蒿蓆蓄蒙蒞蒲蒜蓋蒸蓀蓓蒐蒼蓑蓊蜿蜜蜻蜢蜥蜴蜘蝕蜷蜩裳褂裴裹裸製裨褚裯誦誌語誣認誡誓誤\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0說誥誨誘誑誚誧豪貍貌賓賑賒赫趙趕跼輔輒輕輓辣遠遘遜遣遙遞遢遝遛鄙鄘鄞酵酸酷酴鉸銀銅銘銖鉻銓銜銨鉼銑閡閨閩閣閥閤隙障際雌雒需靼鞅韶頗領颯颱餃餅餌餉駁骯骰髦魁魂鳴鳶鳳麼鼻齊億儀僻僵價儂儈儉儅凜" -- 0xbb
      , "劇劈劉劍劊勰厲嘮嘻嘹嘲嘿嘴嘩噓噎噗噴嘶嘯嘰墀墟增墳墜墮墩墦奭嬉嫻嬋嫵嬌嬈寮寬審寫層履嶝嶔幢幟幡廢廚廟廝廣廠彈影德徵慶慧慮慝慕憂\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0慼慰慫慾憧憐憫憎憬憚憤憔憮戮摩摯摹撞撲撈撐撰撥撓撕撩撒撮播撫撚撬撙撢撳敵敷數暮暫暴暱樣樟槨樁樞標槽模樓樊槳樂樅槭樑歐歎殤毅毆漿潼澄潑潦潔澆潭潛潸潮澎潺潰潤澗潘滕潯潠潟熟熬熱熨牖犛獎獗瑩璋璃" -- 0xbc
      , "瑾璀畿瘠瘩瘟瘤瘦瘡瘢皚皺盤瞎瞇瞌瞑瞋磋磅確磊碾磕碼磐稿稼穀稽稷稻窯窮箭箱範箴篆篇篁箠篌糊締練緯緻緘緬緝編緣線緞緩綞緙緲緹罵罷羯\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0翩耦膛膜膝膠膚膘蔗蔽蔚蓮蔬蔭蔓蔑蔣蔡蔔蓬蔥蓿蔆螂蝴蝶蝠蝦蝸蝨蝙蝗蝌蝓衛衝褐複褒褓褕褊誼諒談諄誕請諸課諉諂調誰論諍誶誹諛豌豎豬賠賞賦賤賬賭賢賣賜質賡赭趟趣踫踐踝踢踏踩踟踡踞躺輝輛輟輩輦輪輜輞" -- 0xbd
      , "輥適遮遨遭遷鄰鄭鄧鄱醇醉醋醃鋅銻銷鋪銬鋤鋁銳銼鋒鋇鋰銲閭閱霄霆震霉靠鞍鞋鞏頡頫頜颳養餓餒餘駝駐駟駛駑駕駒駙骷髮髯鬧魅魄魷魯鴆鴉\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0鴃麩麾黎墨齒儒儘儔儐儕冀冪凝劑劓勳噙噫噹噩噤噸噪器噥噱噯噬噢噶壁墾壇壅奮嬝嬴學寰導彊憲憑憩憊懍憶憾懊懈戰擅擁擋撻撼據擄擇擂操撿擒擔撾整曆曉暹曄曇暸樽樸樺橙橫橘樹橄橢橡橋橇樵機橈歙歷氅濂澱澡" -- 0xbe
      , "濃澤濁澧澳激澹澶澦澠澴熾燉燐燒燈燕熹燎燙燜燃燄獨璜璣璘璟璞瓢甌甍瘴瘸瘺盧盥瞠瞞瞟瞥磨磚磬磧禦積穎穆穌穋窺篙簑築篤篛篡篩篦糕糖縊\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0縑縈縛縣縞縝縉縐罹羲翰翱翮耨膳膩膨臻興艘艙蕊蕙蕈蕨蕩蕃蕉蕭蕪蕞螃螟螞螢融衡褪褲褥褫褡親覦諦諺諫諱謀諜諧諮諾謁謂諷諭諳諶諼豫豭貓賴蹄踱踴蹂踹踵輻輯輸輳辨辦遵遴選遲遼遺鄴醒錠錶鋸錳錯錢鋼錫錄錚" -- 0xbf
      , "錐錦錡錕錮錙閻隧隨險雕霎霑霖霍霓霏靛靜靦鞘頰頸頻頷頭頹頤餐館餞餛餡餚駭駢駱骸骼髻髭鬨鮑鴕鴣鴦鴨鴒鴛默黔龍龜優償儡儲勵嚎嚀嚐嚅嚇\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0嚏壕壓壑壎嬰嬪嬤孺尷屨嶼嶺嶽嶸幫彌徽應懂懇懦懋戲戴擎擊擘擠擰擦擬擱擢擭斂斃曙曖檀檔檄檢檜櫛檣橾檗檐檠歜殮毚氈濘濱濟濠濛濤濫濯澀濬濡濩濕濮濰燧營燮燦燥燭燬燴燠爵牆獰獲璩環璦璨癆療癌盪瞳瞪瞰瞬" -- 0xc0
      , "瞧瞭矯磷磺磴磯礁禧禪穗窿簇簍篾篷簌篠糠糜糞糢糟糙糝縮績繆縷縲繃縫總縱繅繁縴縹繈縵縿縯罄翳翼聱聲聰聯聳臆臃膺臂臀膿膽臉膾臨舉艱薪\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0薄蕾薜薑薔薯薛薇薨薊虧蟀蟑螳蟒蟆螫螻螺蟈蟋褻褶襄褸褽覬謎謗謙講謊謠謝謄謐豁谿豳賺賽購賸賻趨蹉蹋蹈蹊轄輾轂轅輿避遽還邁邂邀鄹醣醞醜鍍鎂錨鍵鍊鍥鍋錘鍾鍬鍛鍰鍚鍔闊闋闌闈闆隱隸雖霜霞鞠韓顆颶餵騁" -- 0xc1
      , "駿鮮鮫鮪鮭鴻鴿麋黏點黜黝黛鼾齋叢嚕嚮壙壘嬸彝懣戳擴擲擾攆擺擻擷斷曜朦檳檬櫃檻檸櫂檮檯歟歸殯瀉瀋濾瀆濺瀑瀏燻燼燾燸獷獵璧璿甕癖癘\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0癒瞽瞿瞻瞼礎禮穡穢穠竄竅簫簧簪簞簣簡糧織繕繞繚繡繒繙罈翹翻職聶臍臏舊藏薩藍藐藉薰薺薹薦蟯蟬蟲蟠覆覲觴謨謹謬謫豐贅蹙蹣蹦蹤蹟蹕軀轉轍邇邃邈醫醬釐鎔鎊鎖鎢鎳鎮鎬鎰鎘鎚鎗闔闖闐闕離雜雙雛雞霤鞣鞦" -- 0xc2
      , "鞭韹額顏題顎顓颺餾餿餽餮馥騎髁鬃鬆魏魎魍鯊鯉鯽鯈鯀鵑鵝鵠黠鼕鼬儳嚥壞壟壢寵龐廬懲懷懶懵攀攏曠曝櫥櫝櫚櫓瀛瀟瀨瀚瀝瀕瀘爆爍牘犢獸\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0獺璽瓊瓣疇疆癟癡矇礙禱穫穩簾簿簸簽簷籀繫繭繹繩繪羅繳羶羹羸臘藩藝藪藕藤藥藷蟻蠅蠍蟹蟾襠襟襖襞譁譜識證譚譎譏譆譙贈贊蹼蹲躇蹶蹬蹺蹴轔轎辭邊邋醱醮鏡鏑鏟鏃鏈鏜鏝鏖鏢鏍鏘鏤鏗鏨關隴難霪霧靡韜韻類" -- 0xc3
      , "願顛颼饅饉騖騙鬍鯨鯧鯖鯛鶉鵡鵲鵪鵬麒麗麓麴勸嚨嚷嚶嚴嚼壤孀孃孽寶巉懸懺攘攔攙曦朧櫬瀾瀰瀲爐獻瓏癢癥礦礪礬礫竇競籌籃籍糯糰辮繽繼\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0纂罌耀臚艦藻藹蘑藺蘆蘋蘇蘊蠔蠕襤覺觸議譬警譯譟譫贏贍躉躁躅躂醴釋鐘鐃鏽闡霰飄饒饑馨騫騰騷騵鰓鰍鹹麵黨鼯齟齣齡儷儸囁囀囂夔屬巍懼懾攝攜斕曩櫻欄櫺殲灌爛犧瓖瓔癩矓籐纏續羼蘗蘭蘚蠣蠢蠡蠟襪襬覽譴" -- 0xc4
      , "護譽贓躊躍躋轟辯醺鐮鐳鐵鐺鐸鐲鐫闢霸霹露響顧顥饗驅驃驀騾髏魔魑鰭鰥鶯鶴鷂鶸麝黯鼙齜齦齧儼儻囈囊囉孿巔巒彎懿攤權歡灑灘玀瓤疊癮癬\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0禳籠籟聾聽臟襲襯觼讀贖贗躑躓轡酈鑄鑑鑒霽霾韃韁顫饕驕驍髒鬚鱉鰱鰾鰻鷓鷗鼴齬齪龔囌巖戀攣攫攪曬欐瓚竊籤籣籥纓纖纔臢蘸蘿蠱變邐邏鑣鑠鑤靨顯饜驚驛驗髓體髑鱔鱗鱖鷥麟黴囑壩攬灞癱癲矗罐羈蠶蠹衢讓讒" -- 0xc5
      , "讖艷贛釀鑪靂靈靄韆顰驟鬢魘鱟鷹鷺鹼鹽鼇齷齲廳欖灣籬籮蠻觀躡釁鑲鑰顱饞髖鬣黌灤矚讚鑷韉驢驥纜讜躪釅鑽鑾鑼鱷鱸黷豔鑿鸚爨驪鬱鸛鸞籲\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0ヾゝゞ々ぁあぃいぅうぇえぉおかがきぎくぐけげこごさざしじすずせぜそぞただちぢっつづてでとどなにぬねのはばぱひびぴふぶぷへべぺほぼぽまみむめもゃやゅゆょよらりるれろゎわゐゑをんァアィイゥウェ" -- 0xc6
      , "エォオカガキギクグケゲコゴサザシジスズセゼソゾタダチヂッツヅテデトドナニヌネノハバパヒビピフブプヘベペホボポマミムメモャヤュユ\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0ョヨラリルレロヮワヰヱヲンヴヵヶДЕЁЖЗИЙКЛМУФХЦЧШЩЪЫЬЭЮЯабвгдеёжзийклмнопрстуфхцчшщъыьэюя①②③④⑤⑥⑦⑧⑨⑩⑴⑵⑶⑷⑸⑹⑺⑻⑼⑽\0\0" -- 0xc7
      , "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" -- 0xc8
      , "乂乜凵匚厂万丌乇亍囗兀屮彳丏冇与丮亓仂仉仈冘勼卬厹圠夃夬尐巿旡殳毌气爿丱丼仨仜仩仡仝仚刌匜卌圢圣夗夯宁宄尒尻屴屳帄庀庂忉戉扐氕\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0氶汃氿氻犮犰玊禸肊阞伎优伬仵伔仱伀价伈伝伂伅伢伓伄仴伒冱刓刉刐劦匢匟卍厊吇囡囟圮圪圴夼妀奼妅奻奾奷奿孖尕尥屼屺屻屾巟幵庄异弚彴忕忔忏扜扞扤扡扦扢扙扠扚扥旯旮朾朹朸朻机朿朼朳氘汆汒汜汏汊汔汋" -- 0xc9
      , "汌灱牞犴犵玎甪癿穵网艸艼芀艽艿虍襾邙邗邘邛邔阢阤阠阣佖伻佢佉体佤伾佧佒佟佁佘伭伳伿佡冏冹刜刞刡劭劮匉卣卲厎厏吰吷吪呔呅吙吜吥吘\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0吽呏呁吨吤呇囮囧囥坁坅坌坉坋坒夆奀妦妘妠妗妎妢妐妏妧妡宎宒尨尪岍岏岈岋岉岒岊岆岓岕巠帊帎庋庉庌庈庍弅弝彸彶忒忑忐忭忨忮忳忡忤忣忺忯忷忻怀忴戺抃抌抎抏抔抇扱扻扺扰抁抈扷扽扲扴攷旰旴旳旲旵杅杇" -- 0xca
      , "杙杕杌杈杝杍杚杋毐氙氚汸汧汫沄沋沏汱汯汩沚汭沇沕沜汦汳汥汻沎灴灺牣犿犽狃狆狁犺狅玕玗玓玔玒町甹疔疕皁礽耴肕肙肐肒肜芐芏芅芎芑芓\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0芊芃芄豸迉辿邟邡邥邞邧邠阰阨阯阭丳侘佼侅佽侀侇佶佴侉侄佷佌侗佪侚佹侁佸侐侜侔侞侒侂侕佫佮冞冼冾刵刲刳剆刱劼匊匋匼厒厔咇呿咁咑咂咈呫呺呾呥呬呴呦咍呯呡呠咘呣呧呤囷囹坯坲坭坫坱坰坶垀坵坻坳坴坢" -- 0xcb
      , "坨坽夌奅妵妺姏姎妲姌姁妶妼姃姖妱妽姀姈妴姇孢孥宓宕屄屇岮岤岠岵岯岨岬岟岣岭岢岪岧岝岥岶岰岦帗帔帙弨弢弣弤彔徂彾彽忞忥怭怦怙怲怋\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0怴怊怗怳怚怞怬怢怍怐怮怓怑怌怉怜戔戽抭抴拑抾抪抶拊抮抳抯抻抩抰抸攽斨斻昉旼昄昒昈旻昃昋昍昅旽昑昐曶朊枅杬枎枒杶杻枘枆构杴枍枌杺枟枑枙枃杽极杸杹枔欥殀歾毞氝沓泬泫泮泙沶泔沭泧沷泐泂沺泃泆泭泲" -- 0xcc
      , "泒泝沴沊沝沀泞泀洰泍泇沰泹泏泩泑炔炘炅炓炆炄炑炖炂炚炃牪狖狋狘狉狜狒狔狚狌狑玤玡玭玦玢玠玬玝瓝瓨甿畀甾疌疘皯盳盱盰盵矸矼矹矻矺\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0矷祂礿秅穸穻竻籵糽耵肏肮肣肸肵肭舠芠苀芫芚芘芛芵芧芮芼芞芺芴芨芡芩苂芤苃芶芢虰虯虭虮豖迒迋迓迍迖迕迗邲邴邯邳邰阹阽阼阺陃俍俅俓侲俉俋俁俔俜俙侻侳俛俇俖侺俀侹俬剄剉勀勂匽卼厗厖厙厘咺咡咭咥哏" -- 0xcd
      , "哃茍咷咮哖咶哅哆咠呰咼咢咾呲哞咰垵垞垟垤垌垗垝垛垔垘垏垙垥垚垕壴复奓姡姞姮娀姱姝姺姽姼姶姤姲姷姛姩姳姵姠姾姴姭宨屌峐峘峌峗峋峛\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0峞峚峉峇峊峖峓峔峏峈峆峎峟峸巹帡帢帣帠帤庰庤庢庛庣庥弇弮彖徆怷怹恔恲恞恅恓恇恉恛恌恀恂恟怤恄恘恦恮扂扃拏挍挋拵挎挃拫拹挏挌拸拶挀挓挔拺挕拻拰敁敃斪斿昶昡昲昵昜昦昢昳昫昺昝昴昹昮朏朐柁柲柈枺" -- 0xce
      , "柜枻柸柘柀枷柅柫柤柟枵柍枳柷柶柮柣柂枹柎柧柰枲柼柆柭柌枮柦柛柺柉柊柃柪柋欨殂殄殶毖毘毠氠氡洨洴洭洟洼洿洒洊泚洳洄洙洺洚洑洀洝浂\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0洁洘洷洃洏浀洇洠洬洈洢洉洐炷炟炾炱炰炡炴炵炩牁牉牊牬牰牳牮狊狤狨狫狟狪狦狣玅珌珂珈珅玹玶玵玴珫玿珇玾珃珆玸珋瓬瓮甮畇畈疧疪癹盄眈眃眄眅眊盷盻盺矧矨砆砑砒砅砐砏砎砉砃砓祊祌祋祅祄秕种秏秖秎窀" -- 0xcf
      , "穾竑笀笁籺籸籹籿粀粁紃紈紁罘羑羍羾耇耎耏耔耷胘胇胠胑胈胂胐胅胣胙胜胊胕胉胏胗胦胍臿舡芔苙苾苹茇苨茀苕茺苫苖苴苬苡苲苵茌苻苶苰苪\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0苤苠苺苳苭虷虴虼虳衁衎衧衪衩觓訄訇赲迣迡迮迠郱邽邿郕郅邾郇郋郈釔釓陔陏陑陓陊陎倞倅倇倓倢倰倛俵俴倳倷倬俶俷倗倜倠倧倵倯倱倎党冔冓凊凄凅凈凎剡剚剒剞剟剕剢勍匎厞唦哢唗唒哧哳哤唚哿唄唈哫唑唅哱" -- 0xd0
      , "唊哻哷哸哠唎唃唋圁圂埌堲埕埒垺埆垽垼垸垶垿埇埐垹埁夎奊娙娖娭娮娕娏娗娊娞娳孬宧宭宬尃屖屔峬峿峮峱峷崀峹帩帨庨庮庪庬弳弰彧恝恚恧\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0恁悢悈悀悒悁悝悃悕悛悗悇悜悎戙扆拲挐捖挬捄捅挶捃揤挹捋捊挼挩捁挴捘捔捙挭捇挳捚捑挸捗捀捈敊敆旆旃旄旂晊晟晇晑朒朓栟栚桉栲栳栻桋桏栖栱栜栵栫栭栯桎桄栴栝栒栔栦栨栮桍栺栥栠欬欯欭欱欴歭肂殈毦毤" -- 0xd1
      , "毨毣毢毧氥浺浣浤浶洍浡涒浘浢浭浯涑涍淯浿涆浞浧浠涗浰浼浟涂涘洯浨涋浾涀涄洖涃浻浽浵涐烜烓烑烝烋缹烢烗烒烞烠烔烍烅烆烇烚烎烡牂牸\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0牷牶猀狺狴狾狶狳狻猁珓珙珥珖玼珧珣珩珜珒珛珔珝珚珗珘珨瓞瓟瓴瓵甡畛畟疰痁疻痄痀疿疶疺皊盉眝眛眐眓眒眣眑眕眙眚眢眧砣砬砢砵砯砨砮砫砡砩砳砪砱祔祛祏祜祓祒祑秫秬秠秮秭秪秜秞秝窆窉窅窋窌窊窇竘笐" -- 0xd2
      , "笄笓笅笏笈笊笎笉笒粄粑粊粌粈粍粅紞紝紑紎紘紖紓紟紒紏紌罜罡罞罠罝罛羖羒翃翂翀耖耾耹胺胲胹胵脁胻脀舁舯舥茳茭荄茙荑茥荖茿荁茦茜茢\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0荂荎茛茪茈茼荍茖茤茠茷茯茩荇荅荌荓茞茬荋茧荈虓虒蚢蚨蚖蚍蚑蚞蚇蚗蚆蚋蚚蚅蚥蚙蚡蚧蚕蚘蚎蚝蚐蚔衃衄衭衵衶衲袀衱衿衯袃衾衴衼訒豇豗豻貤貣赶赸趵趷趶軑軓迾迵适迿迻逄迼迶郖郠郙郚郣郟郥郘郛郗郜郤酐" -- 0xd3
      , "酎酏釕釢釚陜陟隼飣髟鬯乿偰偪偡偞偠偓偋偝偲偈偍偁偛偊偢倕偅偟偩偫偣偤偆偀偮偳偗偑凐剫剭剬剮勖勓匭厜啵啶唼啍啐唴唪啑啢唶唵唰啒啅\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0唌唲啥啎唹啈唭唻啀啋圊圇埻堔埢埶埜埴堀埭埽堈埸堋埳埏堇埮埣埲埥埬埡堎埼堐埧堁堌埱埩埰堍堄奜婠婘婕婧婞娸娵婭婐婟婥婬婓婤婗婃婝婒婄婛婈媎娾婍娹婌婰婩婇婑婖婂婜孲孮寁寀屙崞崋崝崚崠崌崨崍崦崥崏" -- 0xd4
      , "崰崒崣崟崮帾帴庱庴庹庲庳弶弸徛徖徟悊悐悆悾悰悺惓惔惏惤惙惝惈悱惛悷惊悿惃惍惀挲捥掊掂捽掽掞掭掝掗掫掎捯掇掐据掯捵掜捭掮捼掤挻掟\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0捸掅掁掑掍捰敓旍晥晡晛晙晜晢朘桹梇梐梜桭桮梮梫楖桯梣梬梩桵桴梲梏桷梒桼桫桲梪梀桱桾梛梖梋梠梉梤桸桻梑梌梊桽欶欳欷欸殑殏殍殎殌氪淀涫涴涳湴涬淩淢涷淶淔渀淈淠淟淖涾淥淜淝淛淴淊涽淭淰涺淕淂淏淉" -- 0xd5
      , "淐淲淓淽淗淍淣涻烺焍烷焗烴焌烰焄烳焐烼烿焆焓焀烸烶焋焂焎牾牻牼牿猝猗猇猑猘猊猈狿猏猞玈珶珸珵琄琁珽琇琀珺珼珿琌琋珴琈畤畣痎痒痏\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0痋痌痑痐皏皉盓眹眯眭眱眲眴眳眽眥眻眵硈硒硉硍硊硌砦硅硐祤祧祩祪祣祫祡离秺秸秶秷窏窔窐笵筇笴笥笰笢笤笳笘笪笝笱笫笭笯笲笸笚笣粔粘粖粣紵紽紸紶紺絅紬紩絁絇紾紿絊紻紨罣羕羜羝羛翊翋翍翐翑翇翏翉耟" -- 0xd6
      , "耞耛聇聃聈脘脥脙脛脭脟脬脞脡脕脧脝脢舑舸舳舺舴舲艴莐莣莨莍荺荳莤荴莏莁莕莙荵莔莩荽莃莌莝莛莪莋荾莥莯莈莗莰荿莦莇莮荶莚虙虖蚿蚷\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0蛂蛁蛅蚺蚰蛈蚹蚳蚸蛌蚴蚻蚼蛃蚽蚾衒袉袕袨袢袪袚袑袡袟袘袧袙袛袗袤袬袌袓袎覂觖觙觕訰訧訬訞谹谻豜豝豽貥赽赻赹趼跂趹趿跁軘軞軝軜軗軠軡逤逋逑逜逌逡郯郪郰郴郲郳郔郫郬郩酖酘酚酓酕釬釴釱釳釸釤釹釪" -- 0xd7
      , "釫釷釨釮镺閆閈陼陭陫陱陯隿靪頄飥馗傛傕傔傞傋傣傃傌傎傝偨傜傒傂傇兟凔匒匑厤厧喑喨喥喭啷噅喢喓喈喏喵喁喣喒喤啽喌喦啿喕喡喎圌堩堷\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0堙堞堧堣堨埵塈堥堜堛堳堿堶堮堹堸堭堬堻奡媯媔媟婺媢媞婸媦婼媥媬媕媮娷媄媊媗媃媋媩婻婽媌媜媏媓媝寪寍寋寔寑寊寎尌尰崷嵃嵫嵁嵋崿崵嵑嵎嵕崳崺嵒崽崱嵙嵂崹嵉崸崼崲崶嵀嵅幄幁彘徦徥徫惉悹惌惢惎惄愔" -- 0xd8
      , "惲愊愖愅惵愓惸惼惾惁愃愘愝愐惿愄愋扊掔掱掰揎揥揨揯揃撝揳揊揠揶揕揲揵摡揟掾揝揜揄揘揓揂揇揌揋揈揰揗揙攲敧敪敤敜敨敥斌斝斞斮旐旒\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0晼晬晻暀晱晹晪晲朁椌棓椄棜椪棬棪棱椏棖棷棫棤棶椓椐棳棡椇棌椈楰梴椑棯棆椔棸棐棽棼棨椋椊椗棎棈棝棞棦棴棑椆棔棩椕椥棇欹欻欿欼殔殗殙殕殽毰毲毳氰淼湆湇渟湉溈渼渽湅湢渫渿湁湝湳渜渳湋湀湑渻渃渮湞" -- 0xd9
      , "湨湜湡渱渨湠湱湫渹渢渰湓湥渧湸湤湷湕湹湒湦渵渶湚焠焞焯烻焮焱焣焥焢焲焟焨焺焛牋牚犈犉犆犅犋猒猋猰猢猱猳猧猲猭猦猣猵猌琮琬琰琫琖\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0琚琡琭琱琤琣琝琩琠琲瓻甯畯畬痧痚痡痦痝痟痤痗皕皒盚睆睇睄睍睅睊睎睋睌矞矬硠硤硥硜硭硱硪确硰硩硨硞硢祴祳祲祰稂稊稃稌稄窙竦竤筊笻筄筈筌筎筀筘筅粢粞粨粡絘絯絣絓絖絧絪絏絭絜絫絒絔絩絑絟絎缾缿罥" -- 0xda
      , "罦羢羠羡翗聑聏聐胾胔腃腊腒腏腇脽腍脺臦臮臷臸臹舄舼舽舿艵茻菏菹萣菀菨萒菧菤菼菶萐菆菈菫菣莿萁菝菥菘菿菡菋菎菖菵菉萉萏菞萑萆菂菳\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0菕菺菇菑菪萓菃菬菮菄菻菗菢萛菛菾蛘蛢蛦蛓蛣蛚蛪蛝蛫蛜蛬蛩蛗蛨蛑衈衖衕袺裗袹袸裀袾袶袼袷袽袲褁裉覕覘覗觝觚觛詎詍訹詙詀詗詘詄詅詒詈詑詊詌詏豟貁貀貺貾貰貹貵趄趀趉跘跓跍跇跖跜跏跕跙跈跗跅軯軷軺" -- 0xdb
      , "軹軦軮軥軵軧軨軶軫軱軬軴軩逭逴逯鄆鄬鄄郿郼鄈郹郻鄁鄀鄇鄅鄃酡酤酟酢酠鈁鈊鈥鈃鈚鈦鈏鈌鈀鈒釿釽鈆鈄鈧鈂鈜鈤鈙鈗鈅鈖镻閍閌閐隇陾隈\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0隉隃隀雂雈雃雱雰靬靰靮頇颩飫鳦黹亃亄亶傽傿僆傮僄僊傴僈僂傰僁傺傱僋僉傶傸凗剺剸剻剼嗃嗛嗌嗐嗋嗊嗝嗀嗔嗄嗩喿嗒喍嗏嗕嗢嗖嗈嗲嗍嗙嗂圔塓塨塤塏塍塉塯塕塎塝塙塥塛堽塣塱壼嫇嫄嫋媺媸媱媵媰媿嫈媻嫆" -- 0xdc
      , "媷嫀嫊媴媶嫍媹媐寖寘寙尟尳嵱嵣嵊嵥嵲嵬嵞嵨嵧嵢巰幏幎幊幍幋廅廌廆廋廇彀徯徭惷慉慊愫慅愶愲愮慆愯慏愩慀戠酨戣戥戤揅揱揫搐搒搉搠搤\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0搳摃搟搕搘搹搷搢搣搌搦搰搨摁搵搯搊搚摀搥搧搋揧搛搮搡搎敯斒旓暆暌暕暐暋暊暙暔晸朠楦楟椸楎楢楱椿楅楪椹楂楗楙楺楈楉椵楬椳椽楥棰楸椴楩楀楯楄楶楘楁楴楌椻楋椷楜楏楑椲楒椯楻椼歆歅歃歂歈歁殛嗀毻毼" -- 0xdd
      , "毹毷毸溛滖滈溏滀溟溓溔溠溱溹滆滒溽滁溞滉溷溰滍溦滏溲溾滃滜滘溙溒溎溍溤溡溿溳滐滊溗溮溣煇煔煒煣煠煁煝煢煲煸煪煡煂煘煃煋煰煟煐煓\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0煄煍煚牏犍犌犑犐犎猼獂猻猺獀獊獉瑄瑊瑋瑒瑑瑗瑀瑏瑐瑎瑂瑆瑍瑔瓡瓿瓾瓽甝畹畷榃痯瘏瘃痷痾痼痹痸瘐痻痶痭痵痽皙皵盝睕睟睠睒睖睚睩睧睔睙睭矠碇碚碔碏碄碕碅碆碡碃硹碙碀碖硻祼禂祽祹稑稘稙稒稗稕稢稓" -- 0xde
      , "稛稐窣窢窞竫筦筤筭筴筩筲筥筳筱筰筡筸筶筣粲粴粯綈綆綀綍絿綅絺綎絻綃絼綌綔綄絽綒罭罫罧罨罬羦羥羧翛翜耡腤腠腷腜腩腛腢腲朡腞腶腧腯\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0腄腡舝艉艄艀艂艅蓱萿葖葶葹蒏蒍葥葑葀蒆葧萰葍葽葚葙葴葳葝蔇葞萷萺萴葺葃葸萲葅萩菙葋萯葂萭葟葰萹葎葌葒葯蓅蒎萻葇萶萳葨葾葄萫葠葔葮葐蜋蜄蛷蜌蛺蛖蛵蝍蛸蜎蜉蜁蛶蜍蜅裖裋裍裎裞裛裚裌裐覅覛觟觥觤" -- 0xdf
      , "觡觠觢觜触詶誆詿詡訿詷誂誄詵誃誁詴詺谼豋豊豥豤豦貆貄貅賌赨赩趑趌趎趏趍趓趔趐趒跰跠跬跱跮跐跩跣跢跧跲跫跴輆軿輁輀輅輇輈輂輋遒逿\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0遄遉逽鄐鄍鄏鄑鄖鄔鄋鄎酮酯鉈鉒鈰鈺鉦鈳鉥鉞銃鈮鉊鉆鉭鉬鉏鉠鉧鉯鈶鉡鉰鈱鉔鉣鉐鉲鉎鉓鉌鉖鈲閟閜閞閛隒隓隑隗雎雺雽雸雵靳靷靸靲頏頍頎颬飶飹馯馲馰馵骭骫魛鳪鳭鳧麀黽僦僔僗僨僳僛僪僝僤僓僬僰僯僣僠" -- 0xe0
      , "凘劀劁勩勫匰厬嘧嘕嘌嘒嗼嘏嘜嘁嘓嘂嗺嘝嘄嗿嗹墉塼墐墘墆墁塿塴墋塺墇墑墎塶墂墈塻墔墏壾奫嫜嫮嫥嫕嫪嫚嫭嫫嫳嫢嫠嫛嫬嫞嫝嫙嫨嫟孷寠\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0寣屣嶂嶀嵽嶆嵺嶁嵷嶊嶉嶈嵾嵼嶍嵹嵿幘幙幓廘廑廗廎廜廕廙廒廔彄彃彯徶愬愨慁慞慱慳慒慓慲慬憀慴慔慺慛慥愻慪慡慖戩戧戫搫摍摛摝摴摶摲摳摽摵摦撦摎撂摞摜摋摓摠摐摿搿摬摫摙摥摷敳斠暡暠暟朅朄朢榱榶槉" -- 0xe1
      , "榠槎榖榰榬榼榑榙榎榧榍榩榾榯榿槄榽榤槔榹槊榚槏榳榓榪榡榞槙榗榐槂榵榥槆歊歍歋殞殟殠毃毄毾滎滵滱漃漥滸漷滻漮漉潎漙漚漧漘漻漒滭漊\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0漶潳滹滮漭潀漰漼漵滫漇漎潃漅滽滶漹漜滼漺漟漍漞漈漡熇熐熉熀熅熂熏煻熆熁熗牄牓犗犕犓獃獍獑獌瑢瑳瑱瑵瑲瑧瑮甀甂甃畽疐瘖瘈瘌瘕瘑瘊瘔皸瞁睼瞅瞂睮瞀睯睾瞃碲碪碴碭碨硾碫碞碥碠碬碢碤禘禊禋禖禕禔禓" -- 0xe2
      , "禗禈禒禐稫穊稰稯稨稦窨窫窬竮箈箜箊箑箐箖箍箌箛箎箅箘劄箙箤箂粻粿粼粺綧綷緂綣綪緁緀緅綝緎緄緆緋緌綯綹綖綼綟綦綮綩綡緉罳翢翣翥翞\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0耤聝聜膉膆膃膇膍膌膋舕蒗蒤蒡蒟蒺蓎蓂蒬蒮蒫蒹蒴蓁蓍蒪蒚蒱蓐蒝蒧蒻蒢蒔蓇蓌蒛蒩蒯蒨蓖蒘蒶蓏蒠蓗蓔蓒蓛蒰蒑虡蜳蜣蜨蝫蝀蜮蜞蜡蜙蜛蝃蜬蝁蜾蝆蜠蜲蜪蜭蜼蜒蜺蜱蜵蝂蜦蜧蜸蜤蜚蜰蜑裷裧裱裲裺裾裮裼裶裻" -- 0xe3
      , "裰裬裫覝覡覟覞觩觫觨誫誙誋誒誏誖谽豨豩賕賏賗趖踉踂跿踍跽踊踃踇踆踅跾踀踄輐輑輎輍鄣鄜鄠鄢鄟鄝鄚鄤鄡鄛酺酲酹酳銥銤鉶銛鉺銠銔銪銍\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0銦銚銫鉹銗鉿銣鋮銎銂銕銢鉽銈銡銊銆銌銙銧鉾銇銩銝銋鈭隞隡雿靘靽靺靾鞃鞀鞂靻鞄鞁靿韎韍頖颭颮餂餀餇馝馜駃馹馻馺駂馽駇骱髣髧鬾鬿魠魡魟鳱鳲鳵麧僿儃儰僸儆儇僶僾儋儌僽儊劋劌勱勯噈噂噌嘵噁噊噉噆噘" -- 0xe4
      , "噚噀嘳嘽嘬嘾嘸嘪嘺圚墫墝墱墠墣墯墬墥墡壿嫿嫴嫽嫷嫶嬃嫸嬂嫹嬁嬇嬅嬏屧嶙嶗嶟嶒嶢嶓嶕嶠嶜嶡嶚嶞幩幝幠幜緳廛廞廡彉徲憋憃慹憱憰憢憉\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0憛憓憯憭憟憒憪憡憍慦憳戭摮摰撖撠撅撗撜撏撋撊撌撣撟摨撱撘敶敺敹敻斲斳暵暰暩暲暷暪暯樀樆樗槥槸樕槱槤樠槿槬槢樛樝槾樧槲槮樔槷槧橀樈槦槻樍槼槫樉樄樘樥樏槶樦樇槴樖歑殥殣殢殦氁氀毿氂潁漦潾澇濆澒" -- 0xe5
      , "澍澉澌潢潏澅潚澖潶潬澂潕潲潒潐潗澔澓潝漀潡潫潽潧澐潓澋潩潿澕潣潷潪潻熲熯熛熰熠熚熩熵熝熥熞熤熡熪熜熧熳犘犚獘獒獞獟獠獝獛獡獚獙\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0獢璇璉璊璆璁瑽璅璈瑼瑹甈甇畾瘥瘞瘙瘝瘜瘣瘚瘨瘛皜皝皞皛瞍瞏瞉瞈磍碻磏磌磑磎磔磈磃磄磉禚禡禠禜禢禛歶稹窲窴窳箷篋箾箬篎箯箹篊箵糅糈糌糋緷緛緪緧緗緡縃緺緦緶緱緰緮緟罶羬羰羭翭翫翪翬翦翨聤聧膣膟" -- 0xe6
      , "膞膕膢膙膗舖艏艓艒艐艎艑蔤蔻蔏蔀蔩蔎蔉蔍蔟蔊蔧蔜蓻蔫蓺蔈蔌蓴蔪蓲蔕蓷蓫蓳蓼蔒蓪蓩蔖蓾蔨蔝蔮蔂蓽蔞蓶蔱蔦蓧蓨蓰蓯蓹蔘蔠蔰蔋蔙蔯虢\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0蝖蝣蝤蝷蟡蝳蝘蝔蝛蝒蝡蝚蝑蝞蝭蝪蝐蝎蝟蝝蝯蝬蝺蝮蝜蝥蝏蝻蝵蝢蝧蝩衚褅褌褔褋褗褘褙褆褖褑褎褉覢覤覣觭觰觬諏諆誸諓諑諔諕誻諗誾諀諅諘諃誺誽諙谾豍貏賥賟賙賨賚賝賧趠趜趡趛踠踣踥踤踮踕踛踖踑踙踦踧" -- 0xe7
      , "踔踒踘踓踜踗踚輬輤輘輚輠輣輖輗遳遰遯遧遫鄯鄫鄩鄪鄲鄦鄮醅醆醊醁醂醄醀鋐鋃鋄鋀鋙銶鋏鋱鋟鋘鋩鋗鋝鋌鋯鋂鋨鋊鋈鋎鋦鋍鋕鋉鋠鋞鋧鋑鋓\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0銵鋡鋆銴镼閬閫閮閰隤隢雓霅霈霂靚鞊鞎鞈韐韏頞頝頦頩頨頠頛頧颲餈飺餑餔餖餗餕駜駍駏駓駔駎駉駖駘駋駗駌骳髬髫髳髲髱魆魃魧魴魱魦魶魵魰魨魤魬鳼鳺鳽鳿鳷鴇鴀鳹鳻鴈鴅鴄麃黓鼏鼐儜儓儗儚儑凞匴叡噰噠噮" -- 0xe8
      , "噳噦噣噭噲噞噷圜圛壈墽壉墿墺壂墼壆嬗嬙嬛嬡嬔嬓嬐嬖嬨嬚嬠嬞寯嶬嶱嶩嶧嶵嶰嶮嶪嶨嶲嶭嶯嶴幧幨幦幯廩廧廦廨廥彋徼憝憨憖懅憴懆懁懌憺\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0憿憸憌擗擖擐擏擉撽撉擃擛擳擙攳敿敼斢曈暾曀曊曋曏暽暻暺曌朣樴橦橉橧樲橨樾橝橭橶橛橑樨橚樻樿橁橪橤橐橏橔橯橩橠樼橞橖橕橍橎橆歕歔歖殧殪殫毈毇氄氃氆澭濋澣濇澼濎濈潞濄澽澞濊澨瀄澥澮澺澬澪濏澿澸" -- 0xe9
      , "澢濉澫濍澯澲澰燅燂熿熸燖燀燁燋燔燊燇燏熽燘熼燆燚燛犝犞獩獦獧獬獥獫獪瑿璚璠璔璒璕璡甋疀瘯瘭瘱瘽瘳瘼瘵瘲瘰皻盦瞚瞝瞡瞜瞛瞢瞣瞕瞙\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0瞗磝磩磥磪磞磣磛磡磢磭磟磠禤穄穈穇窶窸窵窱窷篞篣篧篝篕篥篚篨篹篔篪篢篜篫篘篟糒糔糗糐糑縒縡縗縌縟縠縓縎縜縕縚縢縋縏縖縍縔縥縤罃罻罼罺羱翯耪耩聬膱膦膮膹膵膫膰膬膴膲膷膧臲艕艖艗蕖蕅蕫蕍蕓蕡蕘" -- 0xea
      , "蕀蕆蕤蕁蕢蕄蕑蕇蕣蔾蕛蕱蕎蕮蕵蕕蕧蕠薌蕦蕝蕔蕥蕬虣虥虤螛螏螗螓螒螈螁螖螘蝹螇螣螅螐螑螝螄螔螜螚螉褞褦褰褭褮褧褱褢褩褣褯褬褟觱諠\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0諢諲諴諵諝謔諤諟諰諈諞諡諨諿諯諻貑貒貐賵賮賱賰賳赬赮趥趧踳踾踸蹀蹅踶踼踽蹁踰踿躽輶輮輵輲輹輷輴遶遹遻邆郺鄳鄵鄶醓醐醑醍醏錧錞錈錟錆錏鍺錸錼錛錣錒錁鍆錭錎錍鋋錝鋺錥錓鋹鋷錴錂錤鋿錩錹錵錪錔錌" -- 0xeb
      , "錋鋾錉錀鋻錖閼闍閾閹閺閶閿閵閽隩雔霋霒霐鞙鞗鞔韰韸頵頯頲餤餟餧餩馞駮駬駥駤駰駣駪駩駧骹骿骴骻髶髺髹髷鬳鮀鮅鮇魼魾魻鮂鮓鮒鮐魺鮕\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0魽鮈鴥鴗鴠鴞鴔鴩鴝鴘鴢鴐鴙鴟麈麆麇麮麭黕黖黺鼒鼽儦儥儢儤儠儩勴嚓嚌嚍嚆嚄嚃噾嚂噿嚁壖壔壏壒嬭嬥嬲嬣嬬嬧嬦嬯嬮孻寱寲嶷幬幪徾徻懃憵憼懧懠懥懤懨懞擯擩擣擫擤擨斁斀斶旚曒檍檖檁檥檉檟檛檡檞檇檓檎" -- 0xec
      , "檕檃檨檤檑橿檦檚檅檌檒歛殭氉濌澩濴濔濣濜濭濧濦濞濲濝濢濨燡燱燨燲燤燰燢獳獮獯璗璲璫璐璪璭璱璥璯甐甑甒甏疄癃癈癉癇皤盩瞵瞫瞲瞷瞶\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0瞴瞱瞨矰磳磽礂磻磼磲礅磹磾礄禫禨穜穛穖穘穔穚窾竀竁簅簏篲簀篿篻簎篴簋篳簂簉簃簁篸篽簆篰篱簐簊糨縭縼繂縳顈縸縪繉繀繇縩繌縰縻縶繄縺罅罿罾罽翴翲耬膻臄臌臊臅臇膼臩艛艚艜薃薀薏薧薕薠薋薣蕻薤薚薞" -- 0xed
      , "蕷蕼薉薡蕺蕸蕗薎薖薆薍薙薝薁薢薂薈薅蕹蕶薘薐薟虨螾螪螭蟅螰螬螹螵螼螮蟉蟃蟂蟌螷螯蟄蟊螴螶螿螸螽蟞螲褵褳褼褾襁襒褷襂覭覯覮觲觳謞\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0謘謖謑謅謋謢謏謒謕謇謍謈謆謜謓謚豏豰豲豱豯貕貔賹赯蹎蹍蹓蹐蹌蹇轃轀邅遾鄸醚醢醛醙醟醡醝醠鎡鎃鎯鍤鍖鍇鍼鍘鍜鍶鍉鍐鍑鍠鍭鎏鍌鍪鍹鍗鍕鍒鍏鍱鍷鍻鍡鍞鍣鍧鎀鍎鍙闇闀闉闃闅閷隮隰隬霠霟霘霝霙鞚鞡鞜" -- 0xee
      , "鞞鞝韕韔韱顁顄顊顉顅顃餥餫餬餪餳餲餯餭餱餰馘馣馡騂駺駴駷駹駸駶駻駽駾駼騃骾髾髽鬁髼魈鮚鮨鮞鮛鮦鮡鮥鮤鮆鮢鮠鮯鴳鵁鵧鴶鴮鴯鴱鴸鴰\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0鵅鵂鵃鴾鴷鵀鴽翵鴭麊麉麍麰黈黚黻黿鼤鼣鼢齔龠儱儭儮嚘嚜嚗嚚嚝嚙奰嬼屩屪巀幭幮懘懟懭懮懱懪懰懫懖懩擿攄擽擸攁攃擼斔旛曚曛曘櫅檹檽櫡櫆檺檶檷櫇檴檭歞毉氋瀇瀌瀍瀁瀅瀔瀎濿瀀濻瀦濼濷瀊爁燿燹爃燽獶" -- 0xef
      , "璸瓀璵瓁璾璶璻瓂甔甓癜癤癙癐癓癗癚皦皽盬矂瞺磿礌礓礔礉礐礒礑禭禬穟簜簩簙簠簟簭簝簦簨簢簥簰繜繐繖繣繘繢繟繑繠繗繓羵羳翷翸聵臑臒\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0臐艟艞薴藆藀藃藂薳薵薽藇藄薿藋藎藈藅薱薶藒蘤薸薷薾虩蟧蟦蟢蟛蟫蟪蟥蟟蟳蟤蟔蟜蟓蟭蟘蟣螤蟗蟙蠁蟴蟨蟝襓襋襏襌襆襐襑襉謪謧謣謳謰謵譇謯謼謾謱謥謷謦謶謮謤謻謽謺豂豵貙貘貗賾贄贂贀蹜蹢蹠蹗蹖蹞蹥蹧" -- 0xf0
      , "蹛蹚蹡蹝蹩蹔轆轇轈轋鄨鄺鄻鄾醨醥醧醯醪鎵鎌鎒鎷鎛鎝鎉鎧鎎鎪鎞鎦鎕鎈鎙鎟鎍鎱鎑鎲鎤鎨鎴鎣鎥闒闓闑隳雗雚巂雟雘雝霣霢霥鞬鞮鞨鞫鞤鞪\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0鞢鞥韗韙韖韘韺顐顑顒颸饁餼餺騏騋騉騍騄騑騊騅騇騆髀髜鬈鬄鬅鬩鬵魊魌魋鯇鯆鯃鮿鯁鮵鮸鯓鮶鯄鮹鮽鵜鵓鵏鵊鵛鵋鵙鵖鵌鵗鵒鵔鵟鵘鵚麎麌黟鼁鼀鼖鼥鼫鼪鼩鼨齌齕儴儵劖勷厴嚫嚭嚦嚧嚪嚬壚壝壛夒嬽嬾嬿巃幰" -- 0xf1
      , "徿懻攇攐攍攉攌攎斄旞旝曞櫧櫠櫌櫑櫙櫋櫟櫜櫐櫫櫏櫍櫞歠殰氌瀙瀧瀠瀖瀫瀡瀢瀣瀩瀗瀤瀜瀪爌爊爇爂爅犥犦犤犣犡瓋瓅璷瓃甖癠矉矊矄矱礝礛\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0礡礜礗礞禰穧穨簳簼簹簬簻糬糪繶繵繸繰繷繯繺繲繴繨罋罊羃羆羷翽翾聸臗臕艤艡艣藫藱藭藙藡藨藚藗藬藲藸藘藟藣藜藑藰藦藯藞藢蠀蟺蠃蟶蟷蠉蠌蠋蠆蟼蠈蟿蠊蠂襢襚襛襗襡襜襘襝襙覈覷覶觶譐譈譊譀譓譖譔譋譕" -- 0xf2
      , "譑譂譒譗豃豷豶貚贆贇贉趬趪趭趫蹭蹸蹳蹪蹯蹻軂轒轑轏轐轓辴酀鄿醰醭鏞鏇鏏鏂鏚鏐鏹鏬鏌鏙鎩鏦鏊鏔鏮鏣鏕鏄鏎鏀鏒鏧镽闚闛雡霩霫霬霨霦\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0鞳鞷鞶韝韞韟顜顙顝顗颿颽颻颾饈饇饃馦馧騚騕騥騝騤騛騢騠騧騣騞騜騔髂鬋鬊鬎鬌鬷鯪鯫鯠鯞鯤鯦鯢鯰鯔鯗鯬鯜鯙鯥鯕鯡鯚鵷鶁鶊鶄鶈鵱鶀鵸鶆鶋鶌鵽鵫鵴鵵鵰鵩鶅鵳鵻鶂鵯鵹鵿鶇鵨麔麑黀黼鼭齀齁齍齖齗齘匷嚲" -- 0xf3
      , "嚵嚳壣孅巆巇廮廯忀忁懹攗攖攕攓旟曨曣曤櫳櫰櫪櫨櫹櫱櫮櫯瀼瀵瀯瀷瀴瀱灂瀸瀿瀺瀹灀瀻瀳灁爓爔犨獽獼璺皫皪皾盭矌矎矏矍矲礥礣礧礨礤礩\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0禲穮穬穭竷籉籈籊籇籅糮繻繾纁纀羺翿聹臛臙舋艨艩蘢藿蘁藾蘛蘀藶蘄蘉蘅蘌藽蠙蠐蠑蠗蠓蠖襣襦覹觷譠譪譝譨譣譥譧譭趮躆躈躄轙轖轗轕轘轚邍酃酁醷醵醲醳鐋鐓鏻鐠鐏鐔鏾鐕鐐鐨鐙鐍鏵鐀鏷鐇鐎鐖鐒鏺鐉鏸鐊鏿" -- 0xf4
      , "鏼鐌鏶鐑鐆闞闠闟霮霯鞹鞻韽韾顠顢顣顟飁飂饐饎饙饌饋饓騲騴騱騬騪騶騩騮騸騭髇髊髆鬐鬒鬑鰋鰈鯷鰅鰒鯸鱀鰇鰎鰆鰗鰔鰉鶟鶙鶤鶝鶒鶘鶐鶛\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0鶠鶔鶜鶪鶗鶡鶚鶢鶨鶞鶣鶿鶩鶖鶦鶧麙麛麚黥黤黧黦鼰鼮齛齠齞齝齙龑儺儹劘劗囃嚽嚾孈孇巋巏廱懽攛欂櫼欃櫸欀灃灄灊灈灉灅灆爝爚爙獾甗癪矐礭礱礯籔籓糲纊纇纈纋纆纍罍羻耰臝蘘蘪蘦蘟蘣蘜蘙蘧蘮蘡蘠蘩蘞蘥" -- 0xf5
      , "蠩蠝蠛蠠蠤蠜蠫衊襭襩襮襫觺譹譸譅譺譻贐贔趯躎躌轞轛轝酆酄酅醹鐿鐻鐶鐩鐽鐼鐰鐹鐪鐷鐬鑀鐱闥闤闣霵霺鞿韡顤飉飆飀饘饖騹騽驆驄驂驁騺\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0騿髍鬕鬗鬘鬖鬺魒鰫鰝鰜鰬鰣鰨鰩鰤鰡鶷鶶鶼鷁鷇鷊鷏鶾鷅鷃鶻鶵鷎鶹鶺鶬鷈鶱鶭鷌鶳鷍鶲鹺麜黫黮黭鼛鼘鼚鼱齎齥齤龒亹囆囅囋奱孋孌巕巑廲攡攠攦攢欋欈欉氍灕灖灗灒爞爟犩獿瓘瓕瓙瓗癭皭礵禴穰穱籗籜籙籛籚" -- 0xf6
      , "糴糱纑罏羇臞艫蘴蘵蘳蘬蘲蘶蠬蠨蠦蠪蠥襱覿覾觻譾讄讂讆讅譿贕躕躔躚躒躐躖躗轠轢酇鑌鑐鑊鑋鑏鑇鑅鑈鑉鑆霿韣顪顩飋饔饛驎驓驔驌驏驈驊\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0驉驒驐髐鬙鬫鬻魖魕鱆鱈鰿鱄鰹鰳鱁鰼鰷鰴鰲鰽鰶鷛鷒鷞鷚鷋鷐鷜鷑鷟鷩鷙鷘鷖鷵鷕鷝麶黰鼵鼳鼲齂齫龕龢儽劙壨壧奲孍巘蠯彏戁戃戄攩攥斖曫欑欒欏毊灛灚爢玂玁玃癰矔籧籦纕艬蘺虀蘹蘼蘱蘻蘾蠰蠲蠮蠳襶襴襳觾" -- 0xf7
      , "讌讎讋讈豅贙躘轤轣醼鑢鑕鑝鑗鑞韄韅頀驖驙鬞鬟鬠鱒鱘鱐鱊鱍鱋鱕鱙鱌鱎鷻鷷鷯鷣鷫鷸鷤鷶鷡鷮鷦鷲鷰鷢鷬鷴鷳鷨鷭黂黐黲黳鼆鼜鼸鼷鼶齃齏\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0齱齰齮齯囓囍孎屭攭曭曮欓灟灡灝灠爣瓛瓥矕礸禷禶籪纗羉艭虃蠸蠷蠵衋讔讕躞躟躠躝醾醽釂鑫鑨鑩雥靆靃靇韇韥驞髕魙鱣鱧鱦鱢鱞鱠鸂鷾鸇鸃鸆鸅鸀鸁鸉鷿鷽鸄麠鼞齆齴齵齶囔攮斸欘欙欗欚灢爦犪矘矙礹籩籫糶纚" -- 0xf8
      , "纘纛纙臠臡虆虇虈襹襺襼襻觿讘讙躥躤躣鑮鑭鑯鑱鑳靉顲饟鱨鱮鱭鸋鸍鸐鸏鸒鸑麡黵鼉齇齸齻齺齹圞灦籯蠼趲躦釃鑴鑸鑶鑵驠鱴鱳鱱鱵鸔鸓黶鼊\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0龤灨灥糷虪蠾蠽蠿讞貜躩軉靋顳顴飌饡馫驤驦驧鬤鸕鸗齈戇欞爧虌躨钂钀钁驩驨鬮鸙爩虋讟钃鱹麷癵驫鱺鸝灩灪麤齾齉龘碁銹裏墻恒粧嫺╔╦╗╠╬╣╚╩╝╒╤╕╞╪╡╘╧╛╓╥╖╟╫╢╙╨╜║═╭╮╰╯▓" -- 0xf9
      ]
  }

-- | Western European (CP1252): the 0x80..0xFF block.  Bytes
-- 0xA0..0xFF coincide with Latin-1; 0x80..0x9F do not.
cp1252High :: U.UArray Int Char
cp1252High = U.listArray (0, 127) "€\0‚ƒ„…†‡ˆ‰Š‹Œ\0Ž\0\0‘’“”•–—˜™š›œ\0žŸ\160¡¢£¤¥¦§¨©ª«¬\173®¯°±²³´µ¶·¸¹º»¼½¾¿ÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÐÑÒÓÔÕÖ×ØÙÚÛÜÝÞßàáâãäåæçèéêëìíîïðñòóôõö÷øùúûüýþÿ"
-- END GENERATED CODEPAGE TABLES


-- BEGIN GENERATED FONT METRICS — AUTO-GENERATED, do not edit.
-- Regenerate (with text_metrics_data.py) via: python3 gen_text_metrics.py
-- Per-glyph (advance, top, bot) in font units, keyed by
-- (face_lc, bold, italic). The Python port lives in text_metrics_data.py;
-- both converters therefore measure text with byte-identical data.
-- freetype-py 2.13.2; faces: Arial / Arial Narrow / Courier New (via the
-- metric-compatible Liberation fonts) plus KiCad Newstroke.

data FaceMetrics = FaceMetrics
  { fmUnitsPerEm :: !Int
  , fmDefaultAdvance :: !Int
  , fmGlyphs :: !(Map.Map Char (Int, Int, Int))
  }
fontMetricsEntry0 :: ((String, Bool, Bool), FaceMetrics)
fontMetricsEntry0 = (("arial", False, False), FaceMetrics 2048 1103 (Map.fromList
  [ (' ', (569, 0, 0))
  , ('!', (569, 1409, 0))
  , ('"', (727, 1409, 966))
  , ('#', (1139, 1401, 0))
  , ('$', (1139, 1516, -142))
  , ('%', (1821, 1421, -12))
  , ('&', (1366, 1417, -20))
  , ('\'', (391, 1409, 966))
  , ('(', (682, 1484, -424))
  , (')', (682, 1484, -424))
  , ('*', (797, 1409, 690))
  , ('+', (1196, 1182, 180))
  , (',', (569, 219, -262))
  , ('-', (682, 624, 464))
  , ('.', (569, 219, 0))
  , ('/', (569, 1484, -20))
  , ('0', (1139, 1430, -20))
  , ('1', (1139, 1409, 0))
  , ('2', (1139, 1430, 0))
  , ('3', (1139, 1430, -20))
  , ('4', (1139, 1409, 0))
  , ('5', (1139, 1409, -20))
  , ('6', (1139, 1430, -20))
  , ('7', (1139, 1409, 0))
  , ('8', (1139, 1430, -20))
  , ('9', (1139, 1430, -20))
  , (':', (569, 1082, 0))
  , (';', (569, 1082, -262))
  , ('<', (1196, 1194, 154))
  , ('=', (1196, 1004, 344))
  , ('>', (1196, 1194, 154))
  , ('?', (1139, 1430, 0))
  , ('@', (2079, 1484, -283))
  , ('A', (1366, 1409, 0))
  , ('B', (1366, 1409, 0))
  , ('C', (1479, 1430, -20))
  , ('D', (1479, 1409, 0))
  , ('E', (1366, 1409, 0))
  , ('F', (1251, 1409, 0))
  , ('G', (1593, 1430, -20))
  , ('H', (1479, 1409, 0))
  , ('I', (569, 1409, 0))
  , ('J', (1024, 1409, -20))
  , ('K', (1366, 1409, 0))
  , ('L', (1139, 1409, 0))
  , ('M', (1706, 1409, 0))
  , ('N', (1479, 1409, 0))
  , ('O', (1593, 1430, -20))
  , ('P', (1366, 1409, 0))
  , ('Q', (1593, 1430, -387))
  , ('R', (1479, 1409, 0))
  , ('S', (1366, 1430, -20))
  , ('T', (1251, 1409, 0))
  , ('U', (1479, 1409, -20))
  , ('V', (1366, 1409, 0))
  , ('W', (1933, 1409, 0))
  , ('X', (1366, 1409, 0))
  , ('Y', (1366, 1409, 0))
  , ('Z', (1251, 1409, 0))
  , ('[', (569, 1484, -425))
  , ('\\', (569, 1484, -20))
  , (']', (569, 1484, -425))
  , ('^', (961, 1409, 673))
  , ('_', (1139, -277, -407))
  , ('`', (682, 1508, 1201))
  , ('a', (1139, 1102, -20))
  , ('b', (1139, 1484, -20))
  , ('c', (1024, 1102, -20))
  , ('d', (1139, 1484, -20))
  , ('e', (1139, 1102, -20))
  , ('f', (569, 1482, 0))
  , ('g', (1139, 1099, -425))
  , ('h', (1139, 1484, 0))
  , ('i', (455, 1484, 0))
  , ('j', (455, 1484, -425))
  , ('k', (1024, 1484, 0))
  , ('l', (455, 1484, 0))
  , ('m', (1706, 1102, 0))
  , ('n', (1139, 1102, 0))
  , ('o', (1139, 1102, -20))
  , ('p', (1139, 1101, -425))
  , ('q', (1139, 1102, -425))
  , ('r', (682, 1102, 0))
  , ('s', (1024, 1099, -20))
  , ('t', (569, 1324, -16))
  , ('u', (1139, 1082, -20))
  , ('v', (1024, 1082, 0))
  , ('w', (1479, 1082, 0))
  , ('x', (1024, 1082, 0))
  , ('y', (1024, 1082, -425))
  , ('z', (1024, 1082, 0))
  , ('{', (684, 1484, -425))
  , ('|', (532, 1484, -434))
  , ('}', (684, 1484, -425))
  , ('~', (1196, 807, 553))
  , ('\xb0', (819, 1430, 860))
  , ('\xb1', (1124, 1219, 0))
  , ('\xb2', (682, 1421, 563))
  , ('\xb3', (682, 1421, 551))
  , ('\xb5', (1180, 1082, -425))
  , ('\xbc', (1708, 1409, -36))
  , ('\xbd', (1708, 1409, 0))
  , ('\xd7', (1196, 1139, 225))
  , ('\xf7', (1124, 1141, 223))
  , ('\x3a9', (1531, 1430, 0))
  , ('\x3bc', (1180, 1082, -393))
  , ('\x2013', (1139, 588, 451))
  , ('\x2014', (2048, 588, 451))
  , ('\x2126', (1573, 1430, 0))
  ]))

fontMetricsEntry1 :: ((String, Bool, Bool), FaceMetrics)
fontMetricsEntry1 = (("arial", True, False), FaceMetrics 2048 1148 (Map.fromList
  [ (' ', (569, 0, 0))
  , ('!', (682, 1409, 0))
  , ('"', (971, 1409, 898))
  , ('#', (1139, 1395, 0))
  , ('$', (1139, 1520, -152))
  , ('%', (1821, 1425, -16))
  , ('&', (1479, 1417, -20))
  , ('\'', (487, 1409, 898))
  , ('(', (682, 1484, -425))
  , (')', (682, 1484, -425))
  , ('*', (797, 1409, 647))
  , ('+', (1196, 1201, 161))
  , (',', (569, 305, -317))
  , ('-', (682, 653, 409))
  , ('.', (569, 305, 0))
  , ('/', (569, 1484, -41))
  , ('0', (1139, 1430, -20))
  , ('1', (1139, 1409, 0))
  , ('2', (1139, 1430, 0))
  , ('3', (1139, 1430, -23))
  , ('4', (1139, 1409, 0))
  , ('5', (1139, 1409, -20))
  , ('6', (1139, 1430, -20))
  , ('7', (1139, 1409, 0))
  , ('8', (1139, 1430, -20))
  , ('9', (1139, 1430, -20))
  , (':', (682, 1034, 0))
  , (';', (682, 1034, -317))
  , ('<', (1196, 1229, 125))
  , ('=', (1196, 1065, 291))
  , ('>', (1196, 1229, 125))
  , ('?', (1251, 1430, 0))
  , ('@', (1997, 1454, -324))
  , ('A', (1479, 1409, 0))
  , ('B', (1479, 1409, 0))
  , ('C', (1479, 1430, -20))
  , ('D', (1479, 1409, 0))
  , ('E', (1366, 1409, 0))
  , ('F', (1251, 1409, 0))
  , ('G', (1593, 1430, -20))
  , ('H', (1479, 1409, 0))
  , ('I', (569, 1409, 0))
  , ('J', (1139, 1409, -20))
  , ('K', (1479, 1409, 0))
  , ('L', (1251, 1409, 0))
  , ('M', (1706, 1409, 0))
  , ('N', (1479, 1409, 0))
  , ('O', (1593, 1430, -20))
  , ('P', (1366, 1409, 0))
  , ('Q', (1593, 1430, -403))
  , ('R', (1479, 1409, 0))
  , ('S', (1366, 1430, -20))
  , ('T', (1251, 1409, 0))
  , ('U', (1479, 1409, -20))
  , ('V', (1366, 1409, 0))
  , ('W', (1933, 1409, 0))
  , ('X', (1366, 1409, 0))
  , ('Y', (1366, 1409, 0))
  , ('Z', (1251, 1409, 0))
  , ('[', (682, 1484, -425))
  , ('\\', (569, 1485, -41))
  , (']', (682, 1484, -425))
  , ('^', (1196, 1409, 514))
  , ('_', (1139, -172, -250))
  , ('`', (682, 1502, 1183))
  , ('a', (1139, 1102, -20))
  , ('b', (1251, 1484, -20))
  , ('c', (1139, 1102, -20))
  , ('d', (1251, 1484, -20))
  , ('e', (1139, 1102, -20))
  , ('f', (682, 1484, 0))
  , ('g', (1251, 1103, -434))
  , ('h', (1251, 1484, 0))
  , ('i', (569, 1484, 0))
  , ('j', (569, 1484, -425))
  , ('k', (1139, 1484, 0))
  , ('l', (569, 1484, 0))
  , ('m', (1821, 1103, 0))
  , ('n', (1251, 1103, 0))
  , ('o', (1251, 1102, -20))
  , ('p', (1251, 1105, -425))
  , ('q', (1251, 1103, -425))
  , ('r', (797, 1103, 0))
  , ('s', (1139, 1103, -20))
  , ('t', (682, 1336, -18))
  , ('u', (1251, 1082, -20))
  , ('v', (1139, 1082, 0))
  , ('w', (1593, 1082, 0))
  , ('x', (1139, 1082, 0))
  , ('y', (1139, 1082, -425))
  , ('z', (1024, 1082, 0))
  , ('{', (797, 1484, -425))
  , ('|', (573, 1484, -455))
  , ('}', (797, 1484, -425))
  , ('~', (1196, 840, 516))
  , ('\xb0', (819, 1425, 795))
  , ('\xb1', (1124, 1270, 0))
  , ('\xb2', (682, 1426, 694))
  , ('\xb3', (682, 1426, 684))
  , ('\xb5', (1180, 1082, -426))
  , ('\xbc', (1708, 1414, -177))
  , ('\xbd', (1708, 1414, -1))
  , ('\xd7', (1196, 1194, 168))
  , ('\xf7', (1124, 1194, 170))
  , ('\x3a9', (1642, 1430, 0))
  , ('\x3bc', (1253, 1082, -416))
  , ('\x2013', (1139, 651, 448))
  , ('\x2014', (2048, 651, 448))
  , ('\x2126', (1573, 1430, 0))
  ]))

fontMetricsEntry2 :: ((String, Bool, Bool), FaceMetrics)
fontMetricsEntry2 = (("arial", False, True), FaceMetrics 2048 1103 (Map.fromList
  [ (' ', (569, 0, 0))
  , ('!', (569, 1409, 0))
  , ('"', (727, 1409, 966))
  , ('#', (1139, 1401, 0))
  , ('$', (1139, 1516, -140))
  , ('%', (1821, 1421, -12))
  , ('&', (1366, 1417, -20))
  , ('\'', (391, 1409, 966))
  , ('(', (682, 1484, -424))
  , (')', (682, 1484, -424))
  , ('*', (797, 1409, 690))
  , ('+', (1196, 1182, 180))
  , (',', (569, 219, -262))
  , ('-', (682, 624, 464))
  , ('.', (569, 219, 0))
  , ('/', (569, 1484, -20))
  , ('0', (1139, 1430, -20))
  , ('1', (1139, 1409, 0))
  , ('2', (1139, 1430, 0))
  , ('3', (1139, 1430, -20))
  , ('4', (1139, 1409, 0))
  , ('5', (1139, 1409, -20))
  , ('6', (1139, 1430, -20))
  , ('7', (1139, 1409, 0))
  , ('8', (1139, 1429, -20))
  , ('9', (1139, 1430, -20))
  , (':', (569, 1082, 0))
  , (';', (569, 1082, -262))
  , ('<', (1196, 1194, 154))
  , ('=', (1196, 1004, 344))
  , ('>', (1196, 1194, 154))
  , ('?', (1139, 1430, 0))
  , ('@', (2079, 1484, -283))
  , ('A', (1366, 1409, 0))
  , ('B', (1366, 1409, 0))
  , ('C', (1479, 1430, -20))
  , ('D', (1479, 1409, 0))
  , ('E', (1366, 1409, 0))
  , ('F', (1251, 1409, 0))
  , ('G', (1593, 1430, -20))
  , ('H', (1479, 1409, 0))
  , ('I', (569, 1409, 0))
  , ('J', (1024, 1409, -20))
  , ('K', (1366, 1409, 0))
  , ('L', (1139, 1409, 0))
  , ('M', (1706, 1409, 0))
  , ('N', (1479, 1409, 0))
  , ('O', (1593, 1430, -20))
  , ('P', (1366, 1409, 0))
  , ('Q', (1593, 1430, -387))
  , ('R', (1479, 1409, 0))
  , ('S', (1366, 1430, -20))
  , ('T', (1251, 1409, 0))
  , ('U', (1479, 1409, -20))
  , ('V', (1366, 1409, 0))
  , ('W', (1933, 1409, 0))
  , ('X', (1366, 1409, 0))
  , ('Y', (1366, 1409, 0))
  , ('Z', (1251, 1409, 0))
  , ('[', (569, 1484, -425))
  , ('\\', (569, 1484, -20))
  , (']', (569, 1484, -425))
  , ('^', (961, 1409, 673))
  , ('_', (1139, -174, -250))
  , ('`', (682, 1508, 1201))
  , ('a', (1139, 1102, -20))
  , ('b', (1139, 1484, -20))
  , ('c', (1024, 1102, -20))
  , ('d', (1139, 1484, -21))
  , ('e', (1139, 1102, -20))
  , ('f', (569, 1484, 0))
  , ('g', (1139, 1101, -425))
  , ('h', (1139, 1484, 0))
  , ('i', (455, 1484, 0))
  , ('j', (455, 1484, -425))
  , ('k', (1024, 1484, 0))
  , ('l', (455, 1484, 0))
  , ('m', (1706, 1101, 0))
  , ('n', (1139, 1101, 0))
  , ('o', (1139, 1101, -20))
  , ('p', (1139, 1102, -425))
  , ('q', (1139, 1101, -425))
  , ('r', (682, 1102, 0))
  , ('s', (1024, 1099, -20))
  , ('t', (569, 1324, -20))
  , ('u', (1139, 1082, -19))
  , ('v', (1024, 1082, 0))
  , ('w', (1479, 1082, 0))
  , ('x', (1024, 1082, 0))
  , ('y', (1024, 1082, -425))
  , ('z', (1024, 1082, 0))
  , ('{', (684, 1484, -425))
  , ('|', (532, 1484, -454))
  , ('}', (684, 1484, -425))
  , ('~', (1196, 807, 553))
  , ('\xb0', (819, 1430, 860))
  , ('\xb1', (1124, 1219, 0))
  , ('\xb2', (682, 1421, 563))
  , ('\xb3', (682, 1421, 551))
  , ('\xb5', (1180, 1082, -425))
  , ('\xbc', (1708, 1409, -56))
  , ('\xbd', (1708, 1409, 0))
  , ('\xd7', (1196, 1139, 225))
  , ('\xf7', (1124, 1141, 223))
  , ('\x3a9', (1558, 1430, 0))
  , ('\x3bc', (1122, 1082, -393))
  , ('\x2013', (1139, 588, 451))
  , ('\x2014', (2048, 588, 451))
  , ('\x2126', (1573, 1430, 0))
  ]))

fontMetricsEntry3 :: ((String, Bool, Bool), FaceMetrics)
fontMetricsEntry3 = (("arial", True, True), FaceMetrics 2048 1147 (Map.fromList
  [ (' ', (569, 0, 0))
  , ('!', (682, 1409, 0))
  , ('"', (971, 1409, 898))
  , ('#', (1139, 1395, 0))
  , ('$', (1139, 1520, -152))
  , ('%', (1821, 1421, -15))
  , ('&', (1479, 1417, -20))
  , ('\'', (487, 1409, 898))
  , ('(', (682, 1484, -425))
  , (')', (682, 1484, -425))
  , ('*', (797, 1409, 647))
  , ('+', (1196, 1201, 161))
  , (',', (569, 305, -317))
  , ('-', (682, 653, 409))
  , ('.', (569, 305, 0))
  , ('/', (569, 1484, -41))
  , ('0', (1139, 1430, -20))
  , ('1', (1139, 1409, 0))
  , ('2', (1139, 1430, 0))
  , ('3', (1139, 1430, -20))
  , ('4', (1139, 1409, 0))
  , ('5', (1139, 1409, -20))
  , ('6', (1139, 1430, -20))
  , ('7', (1139, 1409, 0))
  , ('8', (1139, 1429, -20))
  , ('9', (1139, 1430, -20))
  , (':', (682, 1034, 0))
  , (';', (682, 1034, -317))
  , ('<', (1196, 1229, 125))
  , ('=', (1196, 1065, 291))
  , ('>', (1196, 1229, 125))
  , ('?', (1251, 1430, 0))
  , ('@', (1997, 1484, -294))
  , ('A', (1479, 1409, 0))
  , ('B', (1479, 1409, 0))
  , ('C', (1479, 1430, -20))
  , ('D', (1479, 1409, 0))
  , ('E', (1366, 1409, 0))
  , ('F', (1251, 1409, 0))
  , ('G', (1593, 1430, -19))
  , ('H', (1479, 1409, 0))
  , ('I', (569, 1409, 0))
  , ('J', (1139, 1409, -20))
  , ('K', (1479, 1409, 0))
  , ('L', (1251, 1409, 0))
  , ('M', (1706, 1409, 0))
  , ('N', (1479, 1409, 0))
  , ('O', (1593, 1430, -20))
  , ('P', (1366, 1409, 0))
  , ('Q', (1593, 1430, -400))
  , ('R', (1479, 1409, 0))
  , ('S', (1366, 1430, -20))
  , ('T', (1251, 1409, 0))
  , ('U', (1479, 1409, -20))
  , ('V', (1366, 1409, 0))
  , ('W', (1933, 1409, 0))
  , ('X', (1366, 1409, 0))
  , ('Y', (1366, 1409, 0))
  , ('Z', (1251, 1409, 0))
  , ('[', (682, 1484, -425))
  , ('\\', (569, 1485, -41))
  , (']', (682, 1484, -425))
  , ('^', (1196, 1409, 514))
  , ('_', (1139, -172, -250))
  , ('`', (682, 1502, 1183))
  , ('a', (1139, 1102, -20))
  , ('b', (1251, 1484, -20))
  , ('c', (1139, 1102, -20))
  , ('d', (1251, 1484, -21))
  , ('e', (1139, 1102, -20))
  , ('f', (682, 1484, 0))
  , ('g', (1251, 1101, -425))
  , ('h', (1251, 1484, 0))
  , ('i', (569, 1484, 0))
  , ('j', (569, 1484, -425))
  , ('k', (1139, 1484, 0))
  , ('l', (569, 1484, 0))
  , ('m', (1821, 1101, 0))
  , ('n', (1251, 1101, 0))
  , ('o', (1251, 1101, -20))
  , ('p', (1251, 1102, -425))
  , ('q', (1251, 1102, -425))
  , ('r', (797, 1102, 0))
  , ('s', (1139, 1099, -20))
  , ('t', (682, 1336, -16))
  , ('u', (1251, 1082, -19))
  , ('v', (1139, 1082, 0))
  , ('w', (1593, 1082, 0))
  , ('x', (1139, 1082, 0))
  , ('y', (1139, 1082, -425))
  , ('z', (1024, 1082, 0))
  , ('{', (797, 1484, -425))
  , ('|', (573, 1484, -425))
  , ('}', (797, 1485, -425))
  , ('~', (1196, 840, 516))
  , ('\xb0', (819, 1425, 795))
  , ('\xb1', (1124, 1270, 0))
  , ('\xb2', (682, 1426, 696))
  , ('\xb3', (682, 1426, 688))
  , ('\xb5', (1180, 1082, -425))
  , ('\xbc', (1708, 1413, -191))
  , ('\xbd', (1708, 1413, 0))
  , ('\xd7', (1196, 1194, 168))
  , ('\xf7', (1124, 1194, 170))
  , ('\x3a9', (1599, 1430, 0))
  , ('\x3bc', (1235, 1082, -424))
  , ('\x2013', (1139, 651, 448))
  , ('\x2014', (2048, 651, 448))
  , ('\x2126', (1573, 1430, 0))
  ]))

fontMetricsEntry4 :: ((String, Bool, Bool), FaceMetrics)
fontMetricsEntry4 = (("arial narrow", False, False), FaceMetrics 2048 909 (Map.fromList
  [ (' ', (467, 0, 0))
  , ('!', (467, 1409, 0))
  , ('"', (596, 1409, 966))
  , ('#', (934, 1401, 0))
  , ('$', (934, 1516, -142))
  , ('%', (1493, 1421, -12))
  , ('&', (1120, 1417, -20))
  , ('\'', (322, 1409, 966))
  , ('(', (559, 1484, -424))
  , (')', (559, 1484, -424))
  , ('*', (653, 1409, 690))
  , ('+', (981, 1182, 180))
  , (',', (467, 219, -262))
  , ('-', (559, 624, 464))
  , ('.', (467, 219, 0))
  , ('/', (467, 1484, -20))
  , ('0', (934, 1430, -20))
  , ('1', (934, 1409, 0))
  , ('2', (934, 1430, 0))
  , ('3', (934, 1430, -20))
  , ('4', (934, 1409, 0))
  , ('5', (934, 1409, -20))
  , ('6', (934, 1430, -20))
  , ('7', (934, 1409, 0))
  , ('8', (934, 1430, -20))
  , ('9', (934, 1430, -20))
  , (':', (467, 1082, 0))
  , (';', (467, 1082, -262))
  , ('<', (981, 1194, 154))
  , ('=', (981, 1004, 344))
  , ('>', (981, 1194, 154))
  , ('?', (934, 1430, 0))
  , ('@', (1704, 1484, -283))
  , ('A', (1120, 1409, 0))
  , ('B', (1120, 1409, 0))
  , ('C', (1212, 1430, -20))
  , ('D', (1212, 1409, 0))
  , ('E', (1120, 1409, 0))
  , ('F', (1026, 1409, 0))
  , ('G', (1307, 1430, -20))
  , ('H', (1212, 1409, 0))
  , ('I', (467, 1409, 0))
  , ('J', (840, 1409, -20))
  , ('K', (1120, 1409, 0))
  , ('L', (934, 1409, 0))
  , ('M', (1399, 1409, 0))
  , ('N', (1212, 1409, 0))
  , ('O', (1307, 1430, -20))
  , ('P', (1120, 1409, 0))
  , ('Q', (1307, 1430, -387))
  , ('R', (1212, 1409, 0))
  , ('S', (1120, 1430, -20))
  , ('T', (1026, 1409, 0))
  , ('U', (1212, 1409, -20))
  , ('V', (1120, 1409, 0))
  , ('W', (1585, 1409, 0))
  , ('X', (1120, 1409, 0))
  , ('Y', (1120, 1409, 0))
  , ('Z', (1026, 1409, 0))
  , ('[', (467, 1484, -425))
  , ('\\', (467, 1484, -20))
  , (']', (467, 1484, -425))
  , ('^', (788, 1409, 673))
  , ('_', (934, -277, -407))
  , ('`', (559, 1508, 1201))
  , ('a', (934, 1102, -20))
  , ('b', (934, 1484, -20))
  , ('c', (840, 1102, -20))
  , ('d', (934, 1484, -20))
  , ('e', (934, 1102, -20))
  , ('f', (467, 1482, 0))
  , ('g', (934, 1099, -425))
  , ('h', (934, 1484, 0))
  , ('i', (373, 1484, 0))
  , ('j', (373, 1484, -425))
  , ('k', (840, 1484, 0))
  , ('l', (373, 1484, 0))
  , ('m', (1399, 1102, 0))
  , ('n', (934, 1102, 0))
  , ('o', (934, 1102, -20))
  , ('p', (934, 1101, -425))
  , ('q', (934, 1102, -425))
  , ('r', (559, 1102, 0))
  , ('s', (840, 1099, -20))
  , ('t', (467, 1324, -16))
  , ('u', (934, 1082, -20))
  , ('v', (840, 1082, 0))
  , ('w', (1212, 1082, 0))
  , ('x', (840, 1082, 0))
  , ('y', (840, 1082, -425))
  , ('z', (840, 1082, 0))
  , ('{', (561, 1484, -425))
  , ('|', (436, 1484, -434))
  , ('}', (561, 1484, -425))
  , ('~', (981, 807, 553))
  , ('\xb0', (819, 1430, 860))
  , ('\xb1', (1124, 1219, 0))
  , ('\xb2', (559, 1421, 563))
  , ('\xb3', (559, 1421, 551))
  , ('\xb5', (934, 1082, -425))
  , ('\xbc', (1401, 1409, 0))
  , ('\xbd', (1401, 1409, 0))
  , ('\xd7', (981, 1139, 225))
  , ('\xf7', (1124, 1141, 223))
  , ('\x3a9', (1274, 1430, 0))
  , ('\x3bc', (934, 1082, -393))
  , ('\x2013', (934, 588, 451))
  , ('\x2014', (1679, 588, 451))
  , ('\x2126', (1274, 1430, 0))
  ]))

fontMetricsEntry5 :: ((String, Bool, Bool), FaceMetrics)
fontMetricsEntry5 = (("arial narrow", True, False), FaceMetrics 2048 947 (Map.fromList
  [ (' ', (467, 0, 0))
  , ('!', (559, 1409, 0))
  , ('"', (797, 1409, 898))
  , ('#', (934, 1395, 0))
  , ('$', (934, 1520, -152))
  , ('%', (1493, 1425, -16))
  , ('&', (1212, 1417, -20))
  , ('\'', (399, 1409, 898))
  , ('(', (559, 1484, -425))
  , (')', (559, 1484, -425))
  , ('*', (653, 1409, 647))
  , ('+', (981, 1201, 161))
  , (',', (467, 305, -317))
  , ('-', (559, 653, 409))
  , ('.', (467, 305, 0))
  , ('/', (467, 1484, -41))
  , ('0', (934, 1430, -20))
  , ('1', (934, 1409, 0))
  , ('2', (934, 1430, 0))
  , ('3', (934, 1430, -23))
  , ('4', (934, 1409, 0))
  , ('5', (934, 1409, -20))
  , ('6', (934, 1430, -20))
  , ('7', (934, 1409, 0))
  , ('8', (934, 1430, -20))
  , ('9', (934, 1430, -20))
  , (':', (559, 1034, 0))
  , (';', (559, 1034, -317))
  , ('<', (981, 1229, 125))
  , ('=', (981, 1065, 291))
  , ('>', (981, 1229, 125))
  , ('?', (1026, 1430, 0))
  , ('@', (1638, 1454, -324))
  , ('A', (1212, 1409, 0))
  , ('B', (1212, 1409, 0))
  , ('C', (1212, 1430, -20))
  , ('D', (1212, 1409, 0))
  , ('E', (1120, 1409, 0))
  , ('F', (1026, 1409, 0))
  , ('G', (1307, 1430, -20))
  , ('H', (1212, 1409, 0))
  , ('I', (467, 1409, 0))
  , ('J', (934, 1409, -20))
  , ('K', (1212, 1409, 0))
  , ('L', (1026, 1409, 0))
  , ('M', (1399, 1409, 0))
  , ('N', (1212, 1409, 0))
  , ('O', (1307, 1430, -20))
  , ('P', (1120, 1409, 0))
  , ('Q', (1307, 1430, -403))
  , ('R', (1212, 1409, 0))
  , ('S', (1120, 1430, -20))
  , ('T', (1026, 1409, 0))
  , ('U', (1212, 1409, -20))
  , ('V', (1120, 1409, 0))
  , ('W', (1585, 1409, 0))
  , ('X', (1120, 1409, 0))
  , ('Y', (1120, 1409, 0))
  , ('Z', (1026, 1409, 0))
  , ('[', (559, 1484, -425))
  , ('\\', (467, 1485, -41))
  , (']', (559, 1484, -425))
  , ('^', (981, 1409, 514))
  , ('_', (934, -172, -250))
  , ('`', (559, 1502, 1183))
  , ('a', (934, 1102, -20))
  , ('b', (1026, 1484, -20))
  , ('c', (934, 1102, -20))
  , ('d', (1026, 1484, -20))
  , ('e', (934, 1102, -20))
  , ('f', (559, 1484, 0))
  , ('g', (1026, 1103, -434))
  , ('h', (1026, 1484, 0))
  , ('i', (467, 1484, 0))
  , ('j', (467, 1484, -425))
  , ('k', (934, 1484, 0))
  , ('l', (467, 1484, 0))
  , ('m', (1493, 1103, 0))
  , ('n', (1026, 1103, 0))
  , ('o', (1026, 1102, -20))
  , ('p', (1026, 1105, -425))
  , ('q', (1026, 1103, -425))
  , ('r', (653, 1103, 0))
  , ('s', (934, 1103, -20))
  , ('t', (559, 1336, -18))
  , ('u', (1026, 1082, -20))
  , ('v', (934, 1082, 0))
  , ('w', (1307, 1082, 0))
  , ('x', (934, 1082, 0))
  , ('y', (934, 1082, -425))
  , ('z', (840, 1082, 0))
  , ('{', (653, 1484, -425))
  , ('|', (471, 1484, -455))
  , ('}', (653, 1484, -425))
  , ('~', (981, 840, 516))
  , ('\xb0', (819, 1425, 795))
  , ('\xb1', (1124, 1270, 0))
  , ('\xb2', (559, 1426, 694))
  , ('\xb3', (559, 1426, 684))
  , ('\xb5', (1026, 1082, -426))
  , ('\xbc', (1401, 1414, 0))
  , ('\xbd', (1401, 1414, -1))
  , ('\xd7', (981, 1194, 168))
  , ('\xf7', (1124, 1194, 170))
  , ('\x3a9', (1346, 1430, 0))
  , ('\x3bc', (1026, 1082, -416))
  , ('\x2013', (934, 651, 448))
  , ('\x2014', (1679, 651, 448))
  , ('\x2126', (1346, 1430, 0))
  ]))

fontMetricsEntry6 :: ((String, Bool, Bool), FaceMetrics)
fontMetricsEntry6 = (("arial narrow", False, True), FaceMetrics 2048 913 (Map.fromList
  [ (' ', (467, 0, 0))
  , ('!', (467, 1409, 0))
  , ('"', (596, 1409, 966))
  , ('#', (934, 1401, 0))
  , ('$', (934, 1516, -140))
  , ('%', (1493, 1421, -12))
  , ('&', (1120, 1417, -20))
  , ('\'', (322, 1409, 966))
  , ('(', (559, 1484, -424))
  , (')', (559, 1484, -424))
  , ('*', (653, 1409, 690))
  , ('+', (981, 1182, 180))
  , (',', (467, 219, -262))
  , ('-', (559, 624, 464))
  , ('.', (467, 219, 0))
  , ('/', (467, 1484, -20))
  , ('0', (934, 1430, -20))
  , ('1', (934, 1409, 0))
  , ('2', (934, 1430, 0))
  , ('3', (934, 1430, -20))
  , ('4', (934, 1409, 0))
  , ('5', (934, 1409, -20))
  , ('6', (934, 1430, -20))
  , ('7', (934, 1409, 0))
  , ('8', (934, 1429, -20))
  , ('9', (934, 1430, -20))
  , (':', (467, 1082, 0))
  , (';', (467, 1082, -262))
  , ('<', (981, 1194, 154))
  , ('=', (981, 1004, 344))
  , ('>', (981, 1194, 154))
  , ('?', (934, 1430, 0))
  , ('@', (1704, 1484, -283))
  , ('A', (1120, 1409, 0))
  , ('B', (1120, 1409, 0))
  , ('C', (1212, 1430, -20))
  , ('D', (1212, 1409, 0))
  , ('E', (1120, 1409, 0))
  , ('F', (1026, 1409, 0))
  , ('G', (1307, 1430, -20))
  , ('H', (1212, 1409, 0))
  , ('I', (467, 1409, 0))
  , ('J', (840, 1409, -20))
  , ('K', (1120, 1409, 0))
  , ('L', (934, 1409, 0))
  , ('M', (1399, 1409, 0))
  , ('N', (1212, 1409, 0))
  , ('O', (1307, 1430, -20))
  , ('P', (1120, 1409, 0))
  , ('Q', (1307, 1430, -387))
  , ('R', (1212, 1409, 0))
  , ('S', (1120, 1430, -20))
  , ('T', (1026, 1409, 0))
  , ('U', (1212, 1409, -20))
  , ('V', (1120, 1409, 0))
  , ('W', (1585, 1409, 0))
  , ('X', (1120, 1409, 0))
  , ('Y', (1120, 1409, 0))
  , ('Z', (1026, 1409, 0))
  , ('[', (467, 1484, -425))
  , ('\\', (467, 1484, -20))
  , (']', (467, 1484, -425))
  , ('^', (788, 1409, 673))
  , ('_', (934, -174, -250))
  , ('`', (559, 1508, 1201))
  , ('a', (934, 1102, -20))
  , ('b', (934, 1484, -20))
  , ('c', (840, 1102, -20))
  , ('d', (934, 1484, -21))
  , ('e', (934, 1102, -20))
  , ('f', (467, 1484, 0))
  , ('g', (934, 1101, -425))
  , ('h', (934, 1484, 0))
  , ('i', (373, 1484, 0))
  , ('j', (373, 1484, -425))
  , ('k', (840, 1484, 0))
  , ('l', (373, 1484, 0))
  , ('m', (1399, 1101, 0))
  , ('n', (934, 1101, 0))
  , ('o', (934, 1101, -20))
  , ('p', (934, 1102, -425))
  , ('q', (934, 1101, -425))
  , ('r', (559, 1102, 0))
  , ('s', (840, 1099, -20))
  , ('t', (467, 1324, -20))
  , ('u', (934, 1082, -19))
  , ('v', (840, 1082, 0))
  , ('w', (1212, 1082, 0))
  , ('x', (840, 1082, 0))
  , ('y', (840, 1082, -425))
  , ('z', (840, 1082, 0))
  , ('{', (561, 1484, -425))
  , ('|', (436, 1484, -454))
  , ('}', (561, 1484, -425))
  , ('~', (981, 807, 553))
  , ('\xb0', (819, 1430, 860))
  , ('\xb1', (1124, 1219, 0))
  , ('\xb2', (559, 1421, 563))
  , ('\xb3', (559, 1421, 551))
  , ('\xb5', (1180, 1082, -425))
  , ('\xbc', (1401, 1409, 0))
  , ('\xbd', (1401, 1409, 0))
  , ('\xd7', (981, 1139, 225))
  , ('\xf7', (1124, 1141, 223))
  , ('\x3a9', (1278, 1430, 0))
  , ('\x3bc', (1180, 1082, -393))
  , ('\x2013', (934, 588, 451))
  , ('\x2014', (1679, 588, 451))
  , ('\x2126', (1278, 1430, 0))
  ]))

fontMetricsEntry7 :: ((String, Bool, Bool), FaceMetrics)
fontMetricsEntry7 = (("arial narrow", True, True), FaceMetrics 2048 947 (Map.fromList
  [ (' ', (467, 0, 0))
  , ('!', (559, 1409, 0))
  , ('"', (797, 1409, 898))
  , ('#', (934, 1395, 0))
  , ('$', (934, 1520, -152))
  , ('%', (1493, 1421, -15))
  , ('&', (1212, 1417, -20))
  , ('\'', (399, 1409, 898))
  , ('(', (559, 1484, -425))
  , (')', (559, 1484, -425))
  , ('*', (653, 1409, 647))
  , ('+', (981, 1201, 161))
  , (',', (467, 305, -317))
  , ('-', (559, 653, 409))
  , ('.', (467, 305, 0))
  , ('/', (467, 1484, -41))
  , ('0', (934, 1430, -20))
  , ('1', (934, 1409, 0))
  , ('2', (934, 1430, 0))
  , ('3', (934, 1430, -20))
  , ('4', (934, 1409, 0))
  , ('5', (934, 1409, -20))
  , ('6', (934, 1430, -20))
  , ('7', (934, 1409, 0))
  , ('8', (934, 1429, -20))
  , ('9', (934, 1430, -20))
  , (':', (559, 1034, 0))
  , (';', (559, 1034, -317))
  , ('<', (981, 1229, 125))
  , ('=', (981, 1065, 291))
  , ('>', (981, 1229, 125))
  , ('?', (1026, 1430, 0))
  , ('@', (1638, 1484, -294))
  , ('A', (1212, 1409, 0))
  , ('B', (1212, 1409, 0))
  , ('C', (1212, 1430, -20))
  , ('D', (1212, 1409, 0))
  , ('E', (1120, 1409, 0))
  , ('F', (1026, 1409, 0))
  , ('G', (1307, 1430, -19))
  , ('H', (1212, 1409, 0))
  , ('I', (467, 1409, 0))
  , ('J', (934, 1409, -20))
  , ('K', (1212, 1409, 0))
  , ('L', (1026, 1409, 0))
  , ('M', (1399, 1409, 0))
  , ('N', (1212, 1409, 0))
  , ('O', (1307, 1430, -20))
  , ('P', (1120, 1409, 0))
  , ('Q', (1307, 1430, -400))
  , ('R', (1212, 1409, 0))
  , ('S', (1120, 1430, -20))
  , ('T', (1026, 1409, 0))
  , ('U', (1212, 1409, -20))
  , ('V', (1120, 1409, 0))
  , ('W', (1585, 1409, 0))
  , ('X', (1120, 1409, 0))
  , ('Y', (1120, 1409, 0))
  , ('Z', (1026, 1409, 0))
  , ('[', (559, 1484, -425))
  , ('\\', (467, 1485, -41))
  , (']', (559, 1484, -425))
  , ('^', (981, 1409, 514))
  , ('_', (934, -172, -250))
  , ('`', (559, 1502, 1183))
  , ('a', (934, 1102, -20))
  , ('b', (1026, 1484, -20))
  , ('c', (934, 1102, -20))
  , ('d', (1026, 1484, -21))
  , ('e', (934, 1102, -20))
  , ('f', (559, 1484, 0))
  , ('g', (1026, 1101, -425))
  , ('h', (1026, 1484, 0))
  , ('i', (467, 1484, 0))
  , ('j', (467, 1484, -425))
  , ('k', (934, 1484, 0))
  , ('l', (467, 1484, 0))
  , ('m', (1493, 1101, 0))
  , ('n', (1026, 1101, 0))
  , ('o', (1026, 1101, -20))
  , ('p', (1026, 1102, -425))
  , ('q', (1026, 1102, -425))
  , ('r', (653, 1102, 0))
  , ('s', (934, 1099, -20))
  , ('t', (559, 1336, -16))
  , ('u', (1026, 1082, -19))
  , ('v', (934, 1082, 0))
  , ('w', (1307, 1082, 0))
  , ('x', (934, 1082, 0))
  , ('y', (934, 1082, -425))
  , ('z', (840, 1082, 0))
  , ('{', (653, 1484, -425))
  , ('|', (471, 1484, -425))
  , ('}', (653, 1485, -425))
  , ('~', (981, 840, 516))
  , ('\xb0', (819, 1425, 795))
  , ('\xb1', (1124, 1270, 0))
  , ('\xb2', (559, 1426, 696))
  , ('\xb3', (559, 1426, 688))
  , ('\xb5', (1022, 1082, -425))
  , ('\xbc', (1401, 1413, 0))
  , ('\xbd', (1401, 1413, 0))
  , ('\xd7', (981, 1194, 168))
  , ('\xf7', (1124, 1194, 170))
  , ('\x3a9', (1311, 1430, 0))
  , ('\x3bc', (1022, 1082, -424))
  , ('\x2013', (934, 651, 448))
  , ('\x2014', (1679, 651, 448))
  , ('\x2126', (1311, 1430, 0))
  ]))

fontMetricsEntry8 :: ((String, Bool, Bool), FaceMetrics)
fontMetricsEntry8 = (("courier new", False, False), FaceMetrics 2048 1229 (Map.fromList
  [ (' ', (1229, 0, 0))
  , ('!', (1229, 1348, 0))
  , ('"', (1229, 1484, 845))
  , ('#', (1229, 1349, 0))
  , ('$', (1229, 1476, -141))
  , ('%', (1229, 1361, -12))
  , ('&', (1229, 1357, -20))
  , ('\'', (1229, 1484, 845))
  , ('(', (1229, 1484, -425))
  , (')', (1229, 1484, -425))
  , ('*', (1229, 1483, 764))
  , ('+', (1229, 1182, 180))
  , (',', (1229, 299, -363))
  , ('-', (1229, 624, 464))
  , ('.', (1229, 299, 0))
  , ('/', (1229, 1484, -20))
  , ('0', (1229, 1370, -20))
  , ('1', (1229, 1349, 0))
  , ('2', (1229, 1370, 0))
  , ('3', (1229, 1370, -20))
  , ('4', (1229, 1349, 0))
  , ('5', (1229, 1349, -20))
  , ('6', (1229, 1370, -20))
  , ('7', (1229, 1349, 0))
  , ('8', (1229, 1370, -20))
  , ('9', (1229, 1370, -20))
  , (':', (1229, 1082, 0))
  , (';', (1229, 1082, -363))
  , ('<', (1229, 1194, 154))
  , ('=', (1229, 1004, 344))
  , ('>', (1229, 1194, 154))
  , ('?', (1229, 1370, 0))
  , ('@', (1229, 1484, -283))
  , ('A', (1229, 1349, 0))
  , ('B', (1229, 1349, 0))
  , ('C', (1229, 1370, -20))
  , ('D', (1229, 1349, 0))
  , ('E', (1229, 1349, 0))
  , ('F', (1229, 1349, 0))
  , ('G', (1229, 1370, -20))
  , ('H', (1229, 1349, 0))
  , ('I', (1229, 1349, 0))
  , ('J', (1229, 1349, -20))
  , ('K', (1229, 1349, 0))
  , ('L', (1229, 1349, 0))
  , ('M', (1229, 1349, 0))
  , ('N', (1229, 1349, 0))
  , ('O', (1229, 1370, -20))
  , ('P', (1229, 1349, 0))
  , ('Q', (1229, 1370, -387))
  , ('R', (1229, 1349, 0))
  , ('S', (1229, 1370, -20))
  , ('T', (1229, 1349, 0))
  , ('U', (1229, 1349, -20))
  , ('V', (1229, 1349, 0))
  , ('W', (1229, 1349, 0))
  , ('X', (1229, 1349, 0))
  , ('Y', (1229, 1349, 0))
  , ('Z', (1229, 1349, 0))
  , ('[', (1229, 1484, -425))
  , ('\\', (1229, 1484, -20))
  , (']', (1229, 1484, -425))
  , ('^', (1229, 1349, 442))
  , ('_', (1229, -124, -220))
  , ('`', (1229, 1460, 1201))
  , ('a', (1229, 1102, -20))
  , ('b', (1229, 1484, -20))
  , ('c', (1229, 1102, -20))
  , ('d', (1229, 1484, -26))
  , ('e', (1229, 1102, -20))
  , ('f', (1229, 1484, 0))
  , ('g', (1229, 1099, -424))
  , ('h', (1229, 1484, 0))
  , ('i', (1229, 1484, 0))
  , ('j', (1229, 1484, -425))
  , ('k', (1229, 1484, 0))
  , ('l', (1229, 1484, 0))
  , ('m', (1229, 1102, 0))
  , ('n', (1229, 1102, 0))
  , ('o', (1229, 1102, -20))
  , ('p', (1229, 1104, -425))
  , ('q', (1229, 1098, -425))
  , ('r', (1229, 1102, 0))
  , ('s', (1229, 1099, -20))
  , ('t', (1229, 1364, -16))
  , ('u', (1229, 1082, -20))
  , ('v', (1229, 1082, 0))
  , ('w', (1229, 1082, 0))
  , ('x', (1229, 1082, 0))
  , ('y', (1229, 1082, -425))
  , ('z', (1229, 1082, 0))
  , ('{', (1229, 1484, -425))
  , ('|', (1229, 1484, -425))
  , ('}', (1229, 1484, -425))
  , ('~', (1229, 807, 553))
  , ('\xb0', (1229, 1370, 800))
  , ('\xb1', (1229, 1219, 0))
  , ('\xb2', (1229, 1421, 563))
  , ('\xb3', (1229, 1421, 551))
  , ('\xb5', (1229, 1082, -393))
  , ('\xbc', (1229, 1349, 0))
  , ('\xbd', (1229, 1349, 0))
  , ('\xd7', (1229, 1139, 225))
  , ('\xf7', (1229, 1141, 223))
  , ('\x3a9', (1229, 1370, 0))
  , ('\x3bc', (1229, 1082, -425))
  , ('\x2013', (1229, 588, 451))
  , ('\x2014', (1229, 588, 451))
  , ('\x2126', (1229, 1370, 0))
  ]))

fontMetricsEntry9 :: ((String, Bool, Bool), FaceMetrics)
fontMetricsEntry9 = (("courier new", True, False), FaceMetrics 2048 1229 (Map.fromList
  [ (' ', (1229, 0, 0))
  , ('!', (1229, 1349, 0))
  , ('"', (1229, 1485, 844))
  , ('#', (1229, 1349, 0))
  , ('$', (1229, 1501, -171))
  , ('%', (1229, 1361, -12))
  , ('&', (1229, 1357, -19))
  , ('\'', (1229, 1485, 844))
  , ('(', (1229, 1484, -425))
  , (')', (1229, 1484, -425))
  , ('*', (1229, 1483, 721))
  , ('+', (1229, 1201, 161))
  , (',', (1229, 299, -363))
  , ('-', (1229, 653, 409))
  , ('.', (1229, 305, 0))
  , ('/', (1229, 1484, -20))
  , ('0', (1229, 1370, -20))
  , ('1', (1229, 1349, 0))
  , ('2', (1229, 1370, 0))
  , ('3', (1229, 1370, -23))
  , ('4', (1229, 1349, 0))
  , ('5', (1229, 1349, -20))
  , ('6', (1229, 1370, -20))
  , ('7', (1229, 1349, 0))
  , ('8', (1229, 1370, -20))
  , ('9', (1229, 1370, -20))
  , (':', (1229, 1085, 0))
  , (';', (1229, 1085, -363))
  , ('<', (1229, 1229, 125))
  , ('=', (1229, 1065, 291))
  , ('>', (1229, 1229, 125))
  , ('?', (1229, 1370, 0))
  , ('@', (1229, 1484, -283))
  , ('A', (1229, 1349, 0))
  , ('B', (1229, 1349, 0))
  , ('C', (1229, 1370, -20))
  , ('D', (1229, 1349, 0))
  , ('E', (1229, 1349, 0))
  , ('F', (1229, 1349, 0))
  , ('G', (1229, 1370, -20))
  , ('H', (1229, 1349, 0))
  , ('I', (1229, 1349, 0))
  , ('J', (1229, 1349, -20))
  , ('K', (1229, 1349, 0))
  , ('L', (1229, 1349, 0))
  , ('M', (1229, 1349, 0))
  , ('N', (1229, 1349, 0))
  , ('O', (1229, 1370, -20))
  , ('P', (1229, 1349, 0))
  , ('Q', (1229, 1370, -403))
  , ('R', (1229, 1349, 0))
  , ('S', (1229, 1370, -20))
  , ('T', (1229, 1349, 0))
  , ('U', (1229, 1349, -20))
  , ('V', (1229, 1349, 0))
  , ('W', (1229, 1349, 0))
  , ('X', (1229, 1349, 0))
  , ('Y', (1229, 1349, 0))
  , ('Z', (1229, 1349, 0))
  , ('[', (1229, 1484, -425))
  , ('\\', (1229, 1484, -20))
  , (']', (1229, 1484, -425))
  , ('^', (1229, 1409, 514))
  , ('_', (1229, -124, -220))
  , ('`', (1229, 1458, 1184))
  , ('a', (1229, 1102, -20))
  , ('b', (1229, 1484, -20))
  , ('c', (1229, 1102, -20))
  , ('d', (1229, 1484, -20))
  , ('e', (1229, 1102, -20))
  , ('f', (1229, 1514, 0))
  , ('g', (1229, 1099, -434))
  , ('h', (1229, 1484, 0))
  , ('i', (1229, 1484, 0))
  , ('j', (1229, 1484, -425))
  , ('k', (1229, 1484, 0))
  , ('l', (1229, 1484, 0))
  , ('m', (1229, 1102, 0))
  , ('n', (1229, 1103, 0))
  , ('o', (1229, 1102, -20))
  , ('p', (1229, 1103, -425))
  , ('q', (1229, 1103, -425))
  , ('r', (1229, 1102, 0))
  , ('s', (1229, 1103, -20))
  , ('t', (1229, 1364, -13))
  , ('u', (1229, 1082, -20))
  , ('v', (1229, 1082, 0))
  , ('w', (1229, 1082, 0))
  , ('x', (1229, 1082, 0))
  , ('y', (1229, 1082, -425))
  , ('z', (1229, 1082, 0))
  , ('{', (1229, 1484, -425))
  , ('|', (1229, 1484, -455))
  , ('}', (1229, 1484, -425))
  , ('~', (1229, 840, 516))
  , ('\xb0', (1229, 1425, 795))
  , ('\xb1', (1229, 1270, 0))
  , ('\xb2', (1229, 1422, 563))
  , ('\xb3', (1229, 1421, 551))
  , ('\xb5', (1229, 1082, -416))
  , ('\xbc', (1229, 1349, 0))
  , ('\xbd', (1229, 1349, 0))
  , ('\xd7', (1229, 1194, 168))
  , ('\xf7', (1229, 1194, 170))
  , ('\x3a9', (1229, 1370, 0))
  , ('\x3bc', (1229, 1082, -425))
  , ('\x2013', (1229, 621, 418))
  , ('\x2014', (1229, 621, 418))
  , ('\x2126', (1229, 1370, 0))
  ]))

fontMetricsEntry10 :: ((String, Bool, Bool), FaceMetrics)
fontMetricsEntry10 = (("courier new", False, True), FaceMetrics 2048 1229 (Map.fromList
  [ (' ', (1229, 0, 0))
  , ('!', (1229, 1348, 0))
  , ('"', (1229, 1484, 845))
  , ('#', (1229, 1349, 0))
  , ('$', (1229, 1476, -141))
  , ('%', (1229, 1361, -12))
  , ('&', (1229, 1357, -20))
  , ('\'', (1229, 1484, 845))
  , ('(', (1229, 1484, -425))
  , (')', (1229, 1484, -425))
  , ('*', (1229, 1483, 764))
  , ('+', (1229, 1182, 180))
  , (',', (1229, 299, -363))
  , ('-', (1229, 624, 464))
  , ('.', (1229, 299, 0))
  , ('/', (1229, 1484, -20))
  , ('0', (1229, 1370, -20))
  , ('1', (1229, 1349, 0))
  , ('2', (1229, 1370, 0))
  , ('3', (1229, 1370, -20))
  , ('4', (1229, 1349, 0))
  , ('5', (1229, 1349, -20))
  , ('6', (1229, 1370, -20))
  , ('7', (1229, 1349, 0))
  , ('8', (1229, 1370, -20))
  , ('9', (1229, 1370, -20))
  , (':', (1229, 1082, 0))
  , (';', (1229, 1082, -363))
  , ('<', (1229, 1194, 154))
  , ('=', (1229, 1004, 344))
  , ('>', (1229, 1194, 154))
  , ('?', (1229, 1370, 0))
  , ('@', (1229, 1484, -283))
  , ('A', (1229, 1349, 0))
  , ('B', (1229, 1349, 0))
  , ('C', (1229, 1370, -20))
  , ('D', (1229, 1349, 0))
  , ('E', (1229, 1349, 0))
  , ('F', (1229, 1349, 0))
  , ('G', (1229, 1370, -20))
  , ('H', (1229, 1349, 0))
  , ('I', (1229, 1349, 0))
  , ('J', (1229, 1349, -20))
  , ('K', (1229, 1349, 0))
  , ('L', (1229, 1349, 0))
  , ('M', (1229, 1349, 0))
  , ('N', (1229, 1349, 0))
  , ('O', (1229, 1370, -20))
  , ('P', (1229, 1349, 0))
  , ('Q', (1229, 1370, -387))
  , ('R', (1229, 1349, 0))
  , ('S', (1229, 1370, -20))
  , ('T', (1229, 1349, 0))
  , ('U', (1229, 1349, -20))
  , ('V', (1229, 1349, 0))
  , ('W', (1229, 1349, 0))
  , ('X', (1229, 1349, 0))
  , ('Y', (1229, 1349, 0))
  , ('Z', (1229, 1349, 0))
  , ('[', (1229, 1484, -425))
  , ('\\', (1229, 1484, -20))
  , (']', (1229, 1484, -425))
  , ('^', (1229, 1349, 442))
  , ('_', (1229, -124, -220))
  , ('`', (1229, 1460, 1201))
  , ('a', (1229, 1102, -20))
  , ('b', (1229, 1484, -20))
  , ('c', (1229, 1102, -20))
  , ('d', (1229, 1484, -26))
  , ('e', (1229, 1102, -20))
  , ('f', (1229, 1484, 0))
  , ('g', (1229, 1099, -424))
  , ('h', (1229, 1484, 0))
  , ('i', (1229, 1484, 0))
  , ('j', (1229, 1484, -425))
  , ('k', (1229, 1484, 0))
  , ('l', (1229, 1484, 0))
  , ('m', (1229, 1102, 0))
  , ('n', (1229, 1102, 0))
  , ('o', (1229, 1102, -20))
  , ('p', (1229, 1104, -425))
  , ('q', (1229, 1098, -425))
  , ('r', (1229, 1102, 0))
  , ('s', (1229, 1099, -20))
  , ('t', (1229, 1364, -16))
  , ('u', (1229, 1082, -20))
  , ('v', (1229, 1082, 0))
  , ('w', (1229, 1082, 0))
  , ('x', (1229, 1082, 0))
  , ('y', (1229, 1082, -425))
  , ('z', (1229, 1082, 0))
  , ('{', (1229, 1484, -425))
  , ('|', (1229, 1484, -425))
  , ('}', (1229, 1484, -425))
  , ('~', (1229, 807, 553))
  , ('\xb0', (1229, 1370, 800))
  , ('\xb1', (1229, 1219, 0))
  , ('\xb2', (1229, 1421, 563))
  , ('\xb3', (1229, 1421, 551))
  , ('\xb5', (1229, 1082, -393))
  , ('\xbc', (1229, 1349, 0))
  , ('\xbd', (1229, 1349, 0))
  , ('\xd7', (1229, 1139, 225))
  , ('\xf7', (1229, 1141, 223))
  , ('\x3a9', (1229, 1370, 0))
  , ('\x3bc', (1229, 1082, -425))
  , ('\x2013', (1229, 588, 451))
  , ('\x2014', (1229, 588, 451))
  , ('\x2126', (1229, 1370, 0))
  ]))

fontMetricsEntry11 :: ((String, Bool, Bool), FaceMetrics)
fontMetricsEntry11 = (("courier new", True, True), FaceMetrics 2048 1229 (Map.fromList
  [ (' ', (1229, 0, 0))
  , ('!', (1229, 1349, 0))
  , ('"', (1229, 1485, 844))
  , ('#', (1229, 1349, 0))
  , ('$', (1229, 1501, -171))
  , ('%', (1229, 1361, -12))
  , ('&', (1229, 1357, -19))
  , ('\'', (1229, 1485, 844))
  , ('(', (1229, 1484, -425))
  , (')', (1229, 1484, -425))
  , ('*', (1229, 1483, 721))
  , ('+', (1229, 1201, 161))
  , (',', (1229, 299, -363))
  , ('-', (1229, 653, 409))
  , ('.', (1229, 305, 0))
  , ('/', (1229, 1484, -20))
  , ('0', (1229, 1370, -20))
  , ('1', (1229, 1349, 0))
  , ('2', (1229, 1370, 0))
  , ('3', (1229, 1370, -23))
  , ('4', (1229, 1349, 0))
  , ('5', (1229, 1349, -20))
  , ('6', (1229, 1370, -20))
  , ('7', (1229, 1349, 0))
  , ('8', (1229, 1370, -20))
  , ('9', (1229, 1370, -20))
  , (':', (1229, 1085, 0))
  , (';', (1229, 1085, -363))
  , ('<', (1229, 1229, 125))
  , ('=', (1229, 1065, 291))
  , ('>', (1229, 1229, 125))
  , ('?', (1229, 1370, 0))
  , ('@', (1229, 1484, -283))
  , ('A', (1229, 1349, 0))
  , ('B', (1229, 1349, 0))
  , ('C', (1229, 1370, -20))
  , ('D', (1229, 1349, 0))
  , ('E', (1229, 1349, 0))
  , ('F', (1229, 1349, 0))
  , ('G', (1229, 1370, -20))
  , ('H', (1229, 1349, 0))
  , ('I', (1229, 1349, 0))
  , ('J', (1229, 1349, -20))
  , ('K', (1229, 1349, 0))
  , ('L', (1229, 1349, 0))
  , ('M', (1229, 1349, 0))
  , ('N', (1229, 1349, 0))
  , ('O', (1229, 1370, -20))
  , ('P', (1229, 1349, 0))
  , ('Q', (1229, 1370, -403))
  , ('R', (1229, 1349, 0))
  , ('S', (1229, 1370, -20))
  , ('T', (1229, 1349, 0))
  , ('U', (1229, 1349, -20))
  , ('V', (1229, 1349, 0))
  , ('W', (1229, 1349, 0))
  , ('X', (1229, 1349, 0))
  , ('Y', (1229, 1349, 0))
  , ('Z', (1229, 1349, 0))
  , ('[', (1229, 1484, -425))
  , ('\\', (1229, 1484, -20))
  , (']', (1229, 1484, -425))
  , ('^', (1229, 1409, 514))
  , ('_', (1229, -124, -220))
  , ('`', (1229, 1458, 1184))
  , ('a', (1229, 1102, -20))
  , ('b', (1229, 1484, -20))
  , ('c', (1229, 1102, -20))
  , ('d', (1229, 1484, -20))
  , ('e', (1229, 1102, -20))
  , ('f', (1229, 1514, 0))
  , ('g', (1229, 1099, -434))
  , ('h', (1229, 1484, 0))
  , ('i', (1229, 1484, 0))
  , ('j', (1229, 1484, -425))
  , ('k', (1229, 1484, 0))
  , ('l', (1229, 1484, 0))
  , ('m', (1229, 1102, 0))
  , ('n', (1229, 1103, 0))
  , ('o', (1229, 1102, -20))
  , ('p', (1229, 1103, -425))
  , ('q', (1229, 1103, -425))
  , ('r', (1229, 1102, 0))
  , ('s', (1229, 1103, -20))
  , ('t', (1229, 1364, -13))
  , ('u', (1229, 1082, -20))
  , ('v', (1229, 1082, 0))
  , ('w', (1229, 1082, 0))
  , ('x', (1229, 1082, 0))
  , ('y', (1229, 1082, -425))
  , ('z', (1229, 1082, 0))
  , ('{', (1229, 1484, -425))
  , ('|', (1229, 1484, -455))
  , ('}', (1229, 1484, -425))
  , ('~', (1229, 840, 516))
  , ('\xb0', (1229, 1425, 795))
  , ('\xb1', (1229, 1270, 0))
  , ('\xb2', (1229, 1422, 563))
  , ('\xb3', (1229, 1421, 551))
  , ('\xb5', (1229, 1082, -416))
  , ('\xbc', (1229, 1349, 0))
  , ('\xbd', (1229, 1349, 0))
  , ('\xd7', (1229, 1194, 168))
  , ('\xf7', (1229, 1194, 170))
  , ('\x3a9', (1229, 1370, 0))
  , ('\x3bc', (1229, 1082, -425))
  , ('\x2013', (1229, 621, 418))
  , ('\x2014', (1229, 621, 418))
  , ('\x2126', (1229, 1370, 0))
  ]))

fontMetricsEntry12 :: ((String, Bool, Bool), FaceMetrics)
fontMetricsEntry12 = (("newstroke", False, False), FaceMetrics 21 18 (Map.fromList
  [ (' ', (16, 0, 0))
  , ('!', (10, 12, -9))
  , ('"', (16, 12, 8))
  , ('#', (21, 14, -13))
  , ('$', (20, 15, -12))
  , ('%', (24, 12, -9))
  , ('&', (26, 12, -9))
  , ('\'', (10, 12, 8))
  , ('(', (14, 15, -17))
  , (')', (14, 15, -17))
  , ('*', (16, 12, 3))
  , ('+', (26, 7, -9))
  , (',', (10, -8, -12))
  , ('-', (26, -1, -1))
  , ('.', (10, -7, -9))
  , ('/', (22, 13, -14))
  , ('0', (20, 12, -9))
  , ('1', (20, 12, -9))
  , ('2', (20, 12, -9))
  , ('3', (20, 12, -9))
  , ('4', (20, 13, -9))
  , ('5', (20, 12, -9))
  , ('6', (20, 12, -9))
  , ('7', (20, 12, -9))
  , ('8', (20, 12, -9))
  , ('9', (20, 12, -9))
  , (':', (10, 4, -9))
  , (';', (10, 4, -12))
  , ('<', (26, 5, -7))
  , ('=', (26, 2, -4))
  , ('>', (26, 5, -7))
  , ('?', (18, 12, -9))
  , ('@', (27, 8, -12))
  , ('A', (18, 12, -9))
  , ('B', (21, 12, -9))
  , ('C', (21, 12, -9))
  , ('D', (21, 12, -9))
  , ('E', (19, 12, -9))
  , ('F', (18, 12, -9))
  , ('G', (21, 12, -9))
  , ('H', (22, 12, -9))
  , ('I', (10, 12, -9))
  , ('J', (16, 12, -9))
  , ('K', (21, 12, -9))
  , ('L', (17, 12, -9))
  , ('M', (24, 12, -9))
  , ('N', (22, 12, -9))
  , ('O', (22, 12, -9))
  , ('P', (21, 12, -9))
  , ('Q', (22, 12, -11))
  , ('R', (21, 12, -9))
  , ('S', (20, 12, -9))
  , ('T', (16, 12, -9))
  , ('U', (22, 12, -9))
  , ('V', (18, 12, -9))
  , ('W', (24, 12, -9))
  , ('X', (20, 12, -9))
  , ('Y', (18, 12, -9))
  , ('Z', (20, 12, -9))
  , ('[', (14, 14, -16))
  , ('\\', (14, 14, -13))
  , (']', (14, 14, -16))
  , ('^', (12, 13, 10))
  , ('_', (16, -11, -11))
  , ('`', (8, 13, 10))
  , ('a', (19, 5, -9))
  , ('b', (19, 12, -9))
  , ('c', (18, 5, -9))
  , ('d', (19, 12, -9))
  , ('e', (18, 5, -9))
  , ('f', (12, 12, -9))
  , ('g', (19, 5, -16))
  , ('h', (19, 12, -9))
  , ('i', (10, 12, -9))
  , ('j', (10, 12, -16))
  , ('k', (17, 12, -9))
  , ('l', (11, 12, -9))
  , ('m', (28, 5, -9))
  , ('n', (19, 5, -9))
  , ('o', (19, 5, -9))
  , ('p', (19, 5, -16))
  , ('q', (19, 5, -16))
  , ('r', (13, 5, -9))
  , ('s', (17, 5, -9))
  , ('t', (12, 12, -9))
  , ('u', (19, 5, -9))
  , ('v', (16, 5, -9))
  , ('w', (22, 5, -9))
  , ('x', (17, 5, -9))
  , ('y', (16, 5, -16))
  , ('z', (17, 5, -9))
  , ('{', (14, 15, -17))
  , ('|', (20, 14, -16))
  , ('}', (14, 15, -17))
  , ('~', (15, 1, -1))
  ]))

fontMetricsEntry13 :: ((String, Bool, Bool), FaceMetrics)
fontMetricsEntry13 = (("newstroke", True, False), FaceMetrics 21 18 (Map.fromList
  [ (' ', (16, 0, 0))
  , ('!', (10, 12, -9))
  , ('"', (16, 12, 8))
  , ('#', (21, 14, -13))
  , ('$', (20, 15, -12))
  , ('%', (24, 12, -9))
  , ('&', (26, 12, -9))
  , ('\'', (10, 12, 8))
  , ('(', (14, 15, -17))
  , (')', (14, 15, -17))
  , ('*', (16, 12, 3))
  , ('+', (26, 7, -9))
  , (',', (10, -8, -12))
  , ('-', (26, -1, -1))
  , ('.', (10, -7, -9))
  , ('/', (22, 13, -14))
  , ('0', (20, 12, -9))
  , ('1', (20, 12, -9))
  , ('2', (20, 12, -9))
  , ('3', (20, 12, -9))
  , ('4', (20, 13, -9))
  , ('5', (20, 12, -9))
  , ('6', (20, 12, -9))
  , ('7', (20, 12, -9))
  , ('8', (20, 12, -9))
  , ('9', (20, 12, -9))
  , (':', (10, 4, -9))
  , (';', (10, 4, -12))
  , ('<', (26, 5, -7))
  , ('=', (26, 2, -4))
  , ('>', (26, 5, -7))
  , ('?', (18, 12, -9))
  , ('@', (27, 8, -12))
  , ('A', (18, 12, -9))
  , ('B', (21, 12, -9))
  , ('C', (21, 12, -9))
  , ('D', (21, 12, -9))
  , ('E', (19, 12, -9))
  , ('F', (18, 12, -9))
  , ('G', (21, 12, -9))
  , ('H', (22, 12, -9))
  , ('I', (10, 12, -9))
  , ('J', (16, 12, -9))
  , ('K', (21, 12, -9))
  , ('L', (17, 12, -9))
  , ('M', (24, 12, -9))
  , ('N', (22, 12, -9))
  , ('O', (22, 12, -9))
  , ('P', (21, 12, -9))
  , ('Q', (22, 12, -11))
  , ('R', (21, 12, -9))
  , ('S', (20, 12, -9))
  , ('T', (16, 12, -9))
  , ('U', (22, 12, -9))
  , ('V', (18, 12, -9))
  , ('W', (24, 12, -9))
  , ('X', (20, 12, -9))
  , ('Y', (18, 12, -9))
  , ('Z', (20, 12, -9))
  , ('[', (14, 14, -16))
  , ('\\', (14, 14, -13))
  , (']', (14, 14, -16))
  , ('^', (12, 13, 10))
  , ('_', (16, -11, -11))
  , ('`', (8, 13, 10))
  , ('a', (19, 5, -9))
  , ('b', (19, 12, -9))
  , ('c', (18, 5, -9))
  , ('d', (19, 12, -9))
  , ('e', (18, 5, -9))
  , ('f', (12, 12, -9))
  , ('g', (19, 5, -16))
  , ('h', (19, 12, -9))
  , ('i', (10, 12, -9))
  , ('j', (10, 12, -16))
  , ('k', (17, 12, -9))
  , ('l', (11, 12, -9))
  , ('m', (28, 5, -9))
  , ('n', (19, 5, -9))
  , ('o', (19, 5, -9))
  , ('p', (19, 5, -16))
  , ('q', (19, 5, -16))
  , ('r', (13, 5, -9))
  , ('s', (17, 5, -9))
  , ('t', (12, 12, -9))
  , ('u', (19, 5, -9))
  , ('v', (16, 5, -9))
  , ('w', (22, 5, -9))
  , ('x', (17, 5, -9))
  , ('y', (16, 5, -16))
  , ('z', (17, 5, -9))
  , ('{', (14, 15, -17))
  , ('|', (20, 14, -16))
  , ('}', (14, 15, -17))
  , ('~', (15, 1, -1))
  ]))

fontMetricsEntry14 :: ((String, Bool, Bool), FaceMetrics)
fontMetricsEntry14 = (("newstroke", False, True), FaceMetrics 21 18 (Map.fromList
  [ (' ', (16, 0, 0))
  , ('!', (10, 12, -9))
  , ('"', (16, 12, 8))
  , ('#', (21, 14, -13))
  , ('$', (20, 15, -12))
  , ('%', (24, 12, -9))
  , ('&', (26, 12, -9))
  , ('\'', (10, 12, 8))
  , ('(', (14, 15, -17))
  , (')', (14, 15, -17))
  , ('*', (16, 12, 3))
  , ('+', (26, 7, -9))
  , (',', (10, -8, -12))
  , ('-', (26, -1, -1))
  , ('.', (10, -7, -9))
  , ('/', (22, 13, -14))
  , ('0', (20, 12, -9))
  , ('1', (20, 12, -9))
  , ('2', (20, 12, -9))
  , ('3', (20, 12, -9))
  , ('4', (20, 13, -9))
  , ('5', (20, 12, -9))
  , ('6', (20, 12, -9))
  , ('7', (20, 12, -9))
  , ('8', (20, 12, -9))
  , ('9', (20, 12, -9))
  , (':', (10, 4, -9))
  , (';', (10, 4, -12))
  , ('<', (26, 5, -7))
  , ('=', (26, 2, -4))
  , ('>', (26, 5, -7))
  , ('?', (18, 12, -9))
  , ('@', (27, 8, -12))
  , ('A', (18, 12, -9))
  , ('B', (21, 12, -9))
  , ('C', (21, 12, -9))
  , ('D', (21, 12, -9))
  , ('E', (19, 12, -9))
  , ('F', (18, 12, -9))
  , ('G', (21, 12, -9))
  , ('H', (22, 12, -9))
  , ('I', (10, 12, -9))
  , ('J', (16, 12, -9))
  , ('K', (21, 12, -9))
  , ('L', (17, 12, -9))
  , ('M', (24, 12, -9))
  , ('N', (22, 12, -9))
  , ('O', (22, 12, -9))
  , ('P', (21, 12, -9))
  , ('Q', (22, 12, -11))
  , ('R', (21, 12, -9))
  , ('S', (20, 12, -9))
  , ('T', (16, 12, -9))
  , ('U', (22, 12, -9))
  , ('V', (18, 12, -9))
  , ('W', (24, 12, -9))
  , ('X', (20, 12, -9))
  , ('Y', (18, 12, -9))
  , ('Z', (20, 12, -9))
  , ('[', (14, 14, -16))
  , ('\\', (14, 14, -13))
  , (']', (14, 14, -16))
  , ('^', (12, 13, 10))
  , ('_', (16, -11, -11))
  , ('`', (8, 13, 10))
  , ('a', (19, 5, -9))
  , ('b', (19, 12, -9))
  , ('c', (18, 5, -9))
  , ('d', (19, 12, -9))
  , ('e', (18, 5, -9))
  , ('f', (12, 12, -9))
  , ('g', (19, 5, -16))
  , ('h', (19, 12, -9))
  , ('i', (10, 12, -9))
  , ('j', (10, 12, -16))
  , ('k', (17, 12, -9))
  , ('l', (11, 12, -9))
  , ('m', (28, 5, -9))
  , ('n', (19, 5, -9))
  , ('o', (19, 5, -9))
  , ('p', (19, 5, -16))
  , ('q', (19, 5, -16))
  , ('r', (13, 5, -9))
  , ('s', (17, 5, -9))
  , ('t', (12, 12, -9))
  , ('u', (19, 5, -9))
  , ('v', (16, 5, -9))
  , ('w', (22, 5, -9))
  , ('x', (17, 5, -9))
  , ('y', (16, 5, -16))
  , ('z', (17, 5, -9))
  , ('{', (14, 15, -17))
  , ('|', (20, 14, -16))
  , ('}', (14, 15, -17))
  , ('~', (15, 1, -1))
  ]))

fontMetricsEntry15 :: ((String, Bool, Bool), FaceMetrics)
fontMetricsEntry15 = (("newstroke", True, True), FaceMetrics 21 18 (Map.fromList
  [ (' ', (16, 0, 0))
  , ('!', (10, 12, -9))
  , ('"', (16, 12, 8))
  , ('#', (21, 14, -13))
  , ('$', (20, 15, -12))
  , ('%', (24, 12, -9))
  , ('&', (26, 12, -9))
  , ('\'', (10, 12, 8))
  , ('(', (14, 15, -17))
  , (')', (14, 15, -17))
  , ('*', (16, 12, 3))
  , ('+', (26, 7, -9))
  , (',', (10, -8, -12))
  , ('-', (26, -1, -1))
  , ('.', (10, -7, -9))
  , ('/', (22, 13, -14))
  , ('0', (20, 12, -9))
  , ('1', (20, 12, -9))
  , ('2', (20, 12, -9))
  , ('3', (20, 12, -9))
  , ('4', (20, 13, -9))
  , ('5', (20, 12, -9))
  , ('6', (20, 12, -9))
  , ('7', (20, 12, -9))
  , ('8', (20, 12, -9))
  , ('9', (20, 12, -9))
  , (':', (10, 4, -9))
  , (';', (10, 4, -12))
  , ('<', (26, 5, -7))
  , ('=', (26, 2, -4))
  , ('>', (26, 5, -7))
  , ('?', (18, 12, -9))
  , ('@', (27, 8, -12))
  , ('A', (18, 12, -9))
  , ('B', (21, 12, -9))
  , ('C', (21, 12, -9))
  , ('D', (21, 12, -9))
  , ('E', (19, 12, -9))
  , ('F', (18, 12, -9))
  , ('G', (21, 12, -9))
  , ('H', (22, 12, -9))
  , ('I', (10, 12, -9))
  , ('J', (16, 12, -9))
  , ('K', (21, 12, -9))
  , ('L', (17, 12, -9))
  , ('M', (24, 12, -9))
  , ('N', (22, 12, -9))
  , ('O', (22, 12, -9))
  , ('P', (21, 12, -9))
  , ('Q', (22, 12, -11))
  , ('R', (21, 12, -9))
  , ('S', (20, 12, -9))
  , ('T', (16, 12, -9))
  , ('U', (22, 12, -9))
  , ('V', (18, 12, -9))
  , ('W', (24, 12, -9))
  , ('X', (20, 12, -9))
  , ('Y', (18, 12, -9))
  , ('Z', (20, 12, -9))
  , ('[', (14, 14, -16))
  , ('\\', (14, 14, -13))
  , (']', (14, 14, -16))
  , ('^', (12, 13, 10))
  , ('_', (16, -11, -11))
  , ('`', (8, 13, 10))
  , ('a', (19, 5, -9))
  , ('b', (19, 12, -9))
  , ('c', (18, 5, -9))
  , ('d', (19, 12, -9))
  , ('e', (18, 5, -9))
  , ('f', (12, 12, -9))
  , ('g', (19, 5, -16))
  , ('h', (19, 12, -9))
  , ('i', (10, 12, -9))
  , ('j', (10, 12, -16))
  , ('k', (17, 12, -9))
  , ('l', (11, 12, -9))
  , ('m', (28, 5, -9))
  , ('n', (19, 5, -9))
  , ('o', (19, 5, -9))
  , ('p', (19, 5, -16))
  , ('q', (19, 5, -16))
  , ('r', (13, 5, -9))
  , ('s', (17, 5, -9))
  , ('t', (12, 12, -9))
  , ('u', (19, 5, -9))
  , ('v', (16, 5, -9))
  , ('w', (22, 5, -9))
  , ('x', (17, 5, -9))
  , ('y', (16, 5, -16))
  , ('z', (17, 5, -9))
  , ('{', (14, 15, -17))
  , ('|', (20, 14, -16))
  , ('}', (14, 15, -17))
  , ('~', (15, 1, -1))
  ]))

fontMetrics :: Map.Map (String, Bool, Bool) FaceMetrics
fontMetrics = Map.fromList
  [ fontMetricsEntry0
  , fontMetricsEntry1
  , fontMetricsEntry2
  , fontMetricsEntry3
  , fontMetricsEntry4
  , fontMetricsEntry5
  , fontMetricsEntry6
  , fontMetricsEntry7
  , fontMetricsEntry8
  , fontMetricsEntry9
  , fontMetricsEntry10
  , fontMetricsEntry11
  , fontMetricsEntry12
  , fontMetricsEntry13
  , fontMetricsEntry14
  , fontMetricsEntry15
  ]
-- END GENERATED FONT METRICS
