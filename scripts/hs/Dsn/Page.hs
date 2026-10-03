-- Copyright (C) 2026 Andrei Errapart
-- SPDX-License-Identifier: GPL-2.0-or-later

-- | One schematic page stream (`Views/<view>/Pages/<page>`): header and
-- title block, net table, wires, net aliases, components, off-page
-- connectors, power symbols, free text and graphics.
module Dsn.Page
  ( parsePage
  , pageStreamPath
  ) where

import Binary
  ( byteAt, word16LE, word32LE, int16LE, int32LE
  , findSubFrom, findAll, findAllFrom
  , asciiAt, isPrintableAscii, extractStrings
  , maybeWord32ToInt
  , firstJust, lookupList, listAt, orElse
  , splitSlash
  )
import Control.Monad (guard)
import Data.Bits ((.&.))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Char (toUpper)
import Data.List (isInfixOf, isPrefixOf)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Word (Word32)
import Dsn.Record
  ( recordMarker, netTableAnchor, textRecordType
  , pageRectTag, pageLineTag, pageEllipseTag, pagePolygonTag
  , findCellMatches
  )
import Model
  ( Page(..), Wire(..), NetLabel(..), OffPageConnector(..)
  , Component(..), DisplayField(..), PagePin(..)
  , PowerStyle(..), PowerSymbol(..), Rgba
  , PageText(..), GraphicStyle(..), PageGraphic(..)
  , TitleBlock(..), PageHeader(..)
  , isBusNetName
  , isRefDesignator, sanitizePageName
  , isGroundPowerName, powerRecordStyle
  , orcadPalette, paperSizes
  )
import Orcad.Geometry
  ( orcadPageSize
  , wirePoint1, wirePoint2, pointOnWire
  , transformPowerAnchor, offPageHotpoint
  )
import System.FilePath (takeFileName)

pageStreamPath :: FilePath -> Maybe (String, String)
pageStreamPath path =
  case splitSlash path of
    ["Views", viewName, "Pages", pageName]
      | not (null viewName) && not (null pageName) -> Just (viewName, pageName)
    _ -> Nothing

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
      stamp <- raw
      -- 1990-01-01 .. 2040-01-01, to reject zeroed or misaligned fields.
      -- Compared as Word32: the upper bound does not fit a 32-bit Int.
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
-- date field holds.  The DSN records no time zone.  The division happens in
-- Word32; the resulting day count (under 50,000) fits any Int.
isoDateFromUnix :: Word32 -> String
isoDateFromUnix stamp =
  let (y, m, d) = civilFromDays (fromIntegral (stamp `div` 86400))
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
      parseNetEntries (netCountPos + 2) (fromIntegral netCount)

    -- All `count` entries or nothing.  The anchor is a byte pattern that can
    -- occur by chance; a match whose table breaks off part-way is not a net
    -- table, and keeping the entries read so far would rename real nets.
    parseNetEntries :: Int -> Int -> Maybe (Map.Map Int String)
    parseNetEntries _ 0 = Just Map.empty
    parseNetEntries pos count = do
      (nextPos, netId, name) <- parseOne pos
      -- Later entries are OrCAD's canonical spelling/alias for a reused ID.
      Map.insertWith (\_ laterName -> laterName) netId name
        <$> parseNetEntries nextPos (count - 1)

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
    -- How many display-property records precede the pin records.  A value
    -- larger than the number of records the component has cannot be that
    -- count -- the field was misread or is corrupt -- and honouring it would
    -- skip every pin, so it is ignored and each record is judged on its own.
    -- A count equal to the number of records is legitimate: a part with
    -- display properties and no pins.
    skipCount :: Int
    skipCount =
      let declared = maybe 0 fromIntegral (word16LE body (cellEnd + 20))
      in if declared > length markerOffsets then 0 else declared
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

pageRecordColor :: BS.ByteString -> Int -> Rgba
pageRecordColor body markerAt =
  let colorIndex = maybe 48 fromIntegral (byteAt body (markerAt - 37))
  in orcadPalette !! min 48 colorIndex

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
