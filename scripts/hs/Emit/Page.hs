-- Copyright (C) 2026 Andrei Errapart
-- SPDX-License-Identifier: GPL-2.0-or-later

-- | The per-page schematic emitter: wires, buses, junctions, net labels,
-- placed components and power symbols, page graphics, and page text --
-- everything that belongs to one KiCad `.kicad_sch` page.
module Emit.Page (generatePageSch) where

import Binary (unique)
import Data.Bits ((.&.))
import qualified Data.ByteString as BS
import Data.List (isSuffixOf)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Emit.Symbol (emitSymbolDefinitions, powerLibName)
import Model
  ( Page(..), Wire(..), NetLabel(..), OffPageConnector(..)
  , Component(..), PagePin(..), Pin(..)
  , PowerStyle(..), PowerSymbol(..), Rgba(..)
  , PageText(..), GraphicStyle(..), PageGraphic(..)
  , TextStyle(..), TitleBlock(..)
  , CacheSymbol(..), MultiUnitRegistry(..)
  , RenderConfig(..)
  , emptyCacheSymbol
  , componentUnitInfo, componentLibName, powerReferenceName
  )
import Orcad.PinRelocation (PinRelocation(..), pinRelocation)
import Orcad.Geometry
  ( unitToMm
  , computeJunctions, placeWireLabels
  , BusEntry(..), synthesizeBusEntries, explicitAliasCovers
  , symbolOrigin
  , placedPinPoint, powerHotPoints
  , ellipsePoints
  , componentAngleFor
  , powerSymbolAngle, powerValueAngle
  )
import Sexpr
  ( kAtom, kString, kNode, kInt, kDouble, kRawNum
  , kNo, kYes, kAt, kUuid, kCoord, kXy
  , kStroke
  , kStyledTextEffects, kStyledProperty
  , kColoredStroke, kPageFill, kHiddenProperty
  , renderKicad
  )
import Text.Layout
  ( defaultComponentTextStyle, textStyleForId, normalizedTextRotation
  , nonEmptyTextLines, pageTextSize, pageTextLinePosition
  , componentFieldPlacement, powerValueCenter
  )
import Uuid (deterministicUuid)

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
    -- Pin movement (native pin lengthening, and --kicad-rc device swaps) is
    -- resolved once, in Orcad.PinRelocation; the emitters below only consume
    -- the result.
    relocation = pinRelocation cfg cacheSymbols page
    adjustedWirePoint = relocatedWirePoint relocation
    rcBridgePairs = relocationBridges relocation
    regularWires = relocationWires relocation
    powerPositions = powerHotPoints page

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
    busWires = filter wireIsBus (pageWires page)
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

-- | UUID keys for the objects on one page.  These live with the emitter
-- rather than in Uuid because they take a Page: keeping them here is what
-- leaves Uuid and Sha256 dependency-free.
pageObjectUuid :: BS.ByteString -> Page -> Int -> Int -> String
pageObjectUuid seed page category objectIndex =
  deterministicUuid seed $
    pageStreamName page ++ ":" ++ show category ++ ":" ++ show objectIndex

pagePinUuid :: BS.ByteString -> Page -> Int -> Int -> String
pagePinUuid seed page componentIndex pinIndex =
  pageObjectUuid seed page 3 (componentIndex * 1000000 + pinIndex)
