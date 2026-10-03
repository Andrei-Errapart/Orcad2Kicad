-- Copyright (C) 2026 Andrei Errapart
-- SPDX-License-Identifier: GPL-2.0-or-later

-- | The converter's domain model: the record types every stage passes
-- around, plus the naming and derivation helpers that depend on nothing but
-- those records.
module Model
  ( Page(..), Wire(..), NetLabel(..), OffPageConnector(..)
  , Component(..), DisplayField(..), PagePin(..)
  , PowerStyle(..), PowerSymbol(..), Rgba(..)
  , PageText(..), GraphicStyle(..), PageGraphic(..)
  , TextStyle(..), TitleBlock(..), PageHeader(..)
  , Pin(..), Rect(..), Segment(..), Ellipse(..), ArcShape(..)
  , Polygon(..), Polyline(..), TextAnnotation(..)
  , CacheSymbol(..), MultiUnitRegistry(..)
  , RenderConfig(..)
  , emptyCacheSymbol, cacheSymbolIsEmpty
  , busMemberPrefix, isBusNetName
  , componentUnitInfo, componentLibName, powerReferenceName
  , isRefDesignator, sanitizePageName, kicadItemName
  , isGroundPowerName, powerRecordStyle
  , pinElectricalType, symbolPinVisibility
  , detectMultiUnitComponents, assignPowerReferences
  , canonicalizePageNetNames, disambiguatePageOutputName
  , orcadPalette, paperSizes
  ) where

import Binary
  ( commonStringPrefix, stripStringPrefix, trimTrailingUnderscores, unique )
import Control.Monad (guard)
import Data.Bits ((.&.))
import Data.Char (isAlpha, isAlphaNum, isDigit, ord, toUpper)
import Data.List (isPrefixOf)
import qualified Data.Map.Strict as Map
import Data.Word (Word32)

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
--
-- The modification time is the on-disk u32 Unix `time_t`, kept as `Word32`:
-- `Int` is 32 bits on wasm32, where every stamp from 2038-01-19 on would wrap
-- negative.
data PageHeader = PageHeader
  { pageHeaderName :: String
  , pageHeaderPaper :: String
  , pageHeaderModified :: Maybe Word32
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

-- | The rendering flags, separated from the CLI record so that geometry and
-- text layout do not depend on how the program was invoked.
data RenderConfig = RenderConfig
  { useKicadPower :: Bool
  , useKicadRc :: Bool
  , useKicadFonts :: Bool
  }

disambiguatePageOutputName :: String -> Page -> Page
disambiguatePageOutputName project page
  | pageOutputName page == project ++ ".kicad_sch" =
      page { pageOutputName = project ++ "_sheet.kicad_sch" }
  | otherwise = page

paperSizes :: [String]
paperSizes = ["A0", "A1", "A2", "A3", "A4", "A", "B", "C", "D", "E"]

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

-- | A name KiCad accepts as the item part of a symbol's library ID.  Its
-- `LIB_ID` forbids  < > " \ :  and control characters there -- a colon
-- would even be read as ending a library nickname -- and its own repair
-- (`LIB_ID::FixIllegalChars`) substitutes an underscore, as this does.
kicadItemName :: String -> String
kicadItemName = map fix
  where
    fix char
      | char < ' ' || char `elem` ("<>\"\\:" :: String) = '_'
      | otherwise = char

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

isRefDesignator :: String -> Bool
isRefDesignator ref =
  let (letters, rest) = span isAlpha ref
      (digits, suffix) = span isDigit rest
  in not (null letters)
     && length letters <= 8
     && not (null digits)
     && length suffix <= 1
     && all isAlpha suffix

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
