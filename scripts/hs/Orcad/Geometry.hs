-- Copyright (C) 2026 Andrei Errapart
-- SPDX-License-Identifier: GPL-2.0-or-later

-- | OrCAD's coordinate system: the 10-mil unit, the orientation encoding,
-- symbol origins, and the wire topology (connectivity, junctions, bus
-- entries) derived from placed geometry.
module Orcad.Geometry
  ( unitToMm, orcadPageSize
  , wirePoint1, wirePoint2, pointOnWire
  , computeJunctions, placeWireLabels
  , BusEntry(..), synthesizeBusEntries, explicitAliasCovers
  , forwardOrcadPoint, symbolOrigin, symbolPinsForOutput
  , placedPinPoint, powerHotPoints
  , refinePageComponents
  , directionFromVector, ellipsePoints, arcMidpoint, arcPoints
  , componentAngleFor
  , standardDevicePinPoint, transformPowerAnchor, offPageHotpoint
  , powerSymbolAngle, powerValueAngle, normalizeCachePolygon
  ) where

import Binary
import Data.Bits ((.&.))
import Data.Char (isDigit, toUpper)
import Data.List (elemIndex, isPrefixOf, isSuffixOf, sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, mapMaybe)
import qualified Data.Set as Set
import Model

unitToMm :: Double
unitToMm = 0.254

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

orcadPageSize :: String -> (Int, Int)
orcadPageSize paper = Map.findWithDefault (1654, 1170) paper $ Map.fromList
  [ ("A4", (1170, 827)), ("A3", (1654, 1170)), ("A2", (2340, 1654))
  , ("A1", (3311, 2340)), ("A0", (4681, 3311)), ("A", (1100, 850))
  , ("B", (1700, 1100)), ("C", (2200, 1700)), ("D", (3400, 2200))
  , ("E", (4400, 3400))
  ]

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

powerSymbolAngle :: PowerSymbol -> Int
powerSymbolAngle symbol = ((powerOrient symbol `div` 256) .&. 0x03) * 90

powerValueAngle :: PowerSymbol -> Int
powerValueAngle symbol =
  let angle = fromMaybe (powerSymbolAngle symbol) (powerValueRotation symbol)
      relative = (angle - powerSymbolAngle symbol) `mod` 360
  in if relative >= 180 then relative - 180 else relative

-- | Page position of one of a placed component's cache pins, after the
-- component's own rotation/mirror is applied about its symbol origin.
placedPinPoint :: Component -> CacheSymbol -> Pin -> (Int, Int)
placedPinPoint component symbol pin =
  let center@(centerX, centerY) = symbolOrigin symbol
      (hotX, hotY) = forwardOrcadPoint
        (fromIntegral (pinHotX pin), fromIntegral (pinHotY pin))
        (compOrient component)
        center
  in ( round (fromIntegral (compX component) + hotX - centerX)
     , round (fromIntegral (compY component) + hotY - centerY)
     )

-- | The connection points of a page's power symbols.
powerHotPoints :: Page -> Set.Set (Int, Int)
powerHotPoints page = Set.fromList
  [ (powerHotX symbol, powerHotY symbol)
  | symbol <- pagePowerSymbols page
  ]

-- | Recover each placed component's body origin by matching its cache
-- pins against the pin positions recorded on the page, trying every
-- orientation and keeping the one whose implied origins agree most
-- closely.  A component whose pins cannot be matched is left as parsed.
--
-- Pure coordinate work: it consumes the cache symbols and a page and
-- returns the page, touching nothing above this layer.
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
