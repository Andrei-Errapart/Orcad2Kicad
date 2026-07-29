-- Copyright (C) 2026 Andrei Errapart
-- SPDX-License-Identifier: GPL-2.0-or-later

-- | The Cache stream: per-cell symbol geometry (pins, rectangles, lines,
-- ellipses, arcs, polygons, polylines, text annotations) and pin-name/number
-- visibility flags, keyed by cell name.
module Dsn.Cache
  ( parseCacheSymbols
  ) where

import Binary
  ( byteAt, word16LE, word32LE, int16LE, int32LE
  , readI32Quad, readI32Oct
  , findSubBefore, findAll, findAllFrom
  , asciiAt, maybeWord32ToInt
  , orElse, unique, dedupeConsecutive
  )
import Control.Monad (guard)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Bits ((.&.))
import Data.Char (isAlphaNum)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import Data.Word (Word8)
import Dsn.Record (recordMarker, findCellMatches)
import Model
  ( CacheSymbol(..), Pin(..), Rect(..), Segment(..), Ellipse(..)
  , ArcShape(..), Polygon(..), Polyline(..), TextAnnotation(..)
  , emptyCacheSymbol, cacheSymbolIsEmpty
  )
import Orcad.Geometry (normalizeCachePolygon)

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
