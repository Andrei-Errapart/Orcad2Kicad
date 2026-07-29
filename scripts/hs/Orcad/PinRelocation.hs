-- Copyright (C) 2026 Andrei Errapart
-- SPDX-License-Identifier: GPL-2.0-or-later

-- | Where a page's pins actually end up, and what that does to the wires
-- that land on them.
--
-- Two independent relocations happen before a page is emitted:
--
--   * every symbol's pins are extended to a minimum length so KiCad renders
--     their numbers legibly (`symbolPinsForOutput`), which moves the hot end
--     of each pin away from the body; and
--
--   * under `--kicad-rc`, resistor and capacitor cells are replaced by
--     KiCad's own `Device:R` / `Device:C`, whose pins sit at fixed offsets
--     that generally do not coincide with the OrCAD ones.
--
-- Either way a wire that used to end on a pin no longer does. A wire endpoint
-- may follow its pin only when the move is collinear with the wire, otherwise
-- the wire would change direction; where it cannot follow, and something else
-- is anchored to the old position, a short bridge segment keeps the two
-- connected. Working that out is what this module does.
--
-- It computes geometry only -- no S-expressions -- so it sits below the
-- emitters. Extracted from `generatePageSch`, where it was 17 helpers
-- interleaved with the emission code and reachable only by converting a whole
-- design.
module Orcad.PinRelocation
  ( PinRelocation(..)
  , pinRelocation
  ) where

import Binary (unique)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Model
  ( Page(..), Wire(..), NetLabel(..), Component(..), PagePin(..)
  , CacheSymbol(..), RenderConfig(..)
  )
import Orcad.Geometry
  ( wirePoint1, wirePoint2, pointOnWire
  , placedPinPoint, powerHotPoints, symbolPinsForOutput
  , standardDevicePinPoint
  )

-- | The result of resolving one page's pin movement.
data PinRelocation = PinRelocation
  { relocatedWirePoint :: Wire -> (Int, Int) -> (Int, Int)
    -- ^ Where a wire endpoint should be emitted, given where it was.
  , relocationBridges :: [((Int, Int), (Int, Int))]
    -- ^ Old-to-new segments that must be drawn so a pin that moved away from
    -- something still anchored at its old position stays connected.
  , relocationWires :: [Wire]
    -- ^ The page's non-bus wires, minus those that became internal to a
    -- replaced R/C body and would otherwise short across it.
  }

pinRelocation
  :: RenderConfig -> Map.Map String CacheSymbol -> Page -> PinRelocation
pinRelocation cfg cacheSymbols page = PinRelocation
  { relocatedWirePoint = adjustedWirePoint
  , relocationBridges = rcBridgePairs
  , relocationWires = regularWires
  }
  where
    adjustedWirePoint wire point =
      case Map.lookup point rcPinAdjustmentMap of
        Just newPoint
          | wireEndpointCanMove wire point newPoint -> newPoint
        _ -> Map.findWithDefault point point nativePinAdjustmentMap

    regularWires =
      [ wire
      | wire <- pageWires page
      , not (wireIsBus wire)
      , not (Set.member (orderedWirePoints wire) rcInternalConnections)
      ]
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
    powerPositions = powerHotPoints page
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
