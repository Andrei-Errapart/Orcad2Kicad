-- Copyright (C) 2026 Andrei Errapart
-- SPDX-License-Identifier: GPL-2.0-or-later

-- | Symbol-library emitters: per-cell KiCad `lib_symbols` definitions (both
-- as embedded per-page caches and the project-wide .kicad_sym), plus the
-- bundled standard power/device glyphs used by --kicad-power / --kicad-rc.
module Emit.Symbol
  ( emitSymbolDefinitions, powerLibName, generateSymbolLibrary
  ) where

import Data.Char (toUpper)
import Data.List (isPrefixOf, sortOn)
import qualified Data.Map.Strict as Map
import Model
  ( Page(..), Component(..), PowerStyle(..), PowerSymbol(..)
  , Pin(..), Rect(..), Segment(..), Ellipse(..), ArcShape(..)
  , Polygon(..), Polyline(..), TextAnnotation(..)
  , CacheSymbol(..), MultiUnitRegistry(..)
  , RenderConfig(..)
  , emptyCacheSymbol
  , componentUnitInfo, componentLibName, kicadItemName
  , pinElectricalType, symbolPinVisibility
  )
import Orcad.Geometry
  ( unitToMm
  , symbolOrigin, symbolPinsForOutput
  , directionFromVector, ellipsePoints, arcMidpoint, arcPoints
  )
import Sexpr
  ( KExpr(..)
  , kAtom, kString, kNode, kInt, kDouble, kRawNum
  , kNo, kYes, kAt
  , kStroke, kFillType, kPolylineShape, kCircleShape, kArcShape
  , kTextEffects, kProperty, kHiddenProperty
  , renderKicad
  )
import Text.Layout (orcadOverlineToKicad)

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

    -- Keyed by library ID, which is the net name made legal for KiCad; the
    -- net name itself rides along as the definition's default Value.
    powerDefinitions = Map.toAscList $ Map.fromListWith preferPowerStyle
      [ (powerLibName cfg symbol, (powerNetName symbol, powerStyle symbol))
      | symbol <- powerSymbols
      , not (null (powerNetName symbol))
      ]

    preferPowerStyle (name, PowerGround) _ = (name, PowerGround)
    preferPowerStyle _ (name, PowerGround) = (name, PowerGround)
    preferPowerStyle new _ = new

    emitPowerDefinition (libName, (netName, style))
      | useKicadPower cfg = libStandardPowerSymbol libName
      | otherwise = libPowerSymbol libName netName style

-- | An OrCAD-style power glyph.  `libName` identifies the symbol and so must
-- be legal in a KiCad library ID; `name` is the net it stands for, shown as
-- the Value and pin name, spelled as in the design.
libPowerSymbol :: String -> String -> PowerStyle -> KExpr
libPowerSymbol libName name style =
  kNode "symbol" $
    [ kString ("power:" ++ libName)
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
    , kNode "symbol" (kString (libName ++ "_0_1") : glyph)
    , kNode "symbol"
        [ kString (libName ++ "_1_1")
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

-- | The item name of a power symbol's library ID ("power:<this>").
powerLibName :: RenderConfig -> PowerSymbol -> String
powerLibName cfg symbol
  | not (useKicadPower cfg) = kicadItemName (powerNetName symbol)
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
