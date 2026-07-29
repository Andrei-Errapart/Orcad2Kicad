-- Copyright (C) 2026 Andrei Errapart
-- SPDX-License-Identifier: GPL-2.0-or-later

-- | Text measurement and placement: turning OrCAD's top-left display-property
-- anchors into KiCad's centre anchors, sizing page-text boxes, and translating
-- OrCAD's backslash overline markup into KiCad's ~{...} form.  Returns
-- placements as plain numbers rather than 'Sexpr.KExpr' nodes, so measurement
-- stays independent of S-expression construction.
module Text.Layout
  ( defaultComponentTextStyle, textStyleForId, normalizedTextRotation
  , nonEmptyTextLines, pageTextSize, pageTextLinePosition
  , componentFieldPlacement, powerValueCenter
  , orcadOverlineToKicad
  ) where

import Binary (firstJust)
import Data.Char (isAlpha, isSpace, toLower)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Model
  ( Component(..), DisplayField(..), PageText(..), PowerSymbol(..)
  , RenderConfig(..), TextStyle(..)
  )
import Orcad.Geometry (componentAngleFor, unitToMm)
import Text.MetricsTables (FaceMetrics(..), fontMetrics)

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

-- | Centre anchor and rotation for a component's Reference/Value field.
-- Returns the placement rather than a KExpr node so that measurement stays
-- independent of S-expression construction; Emit.Page builds the `at`.
componentFieldPlacement
  :: RenderConfig -> Component -> DisplayField -> String -> Double
  -> String -> Bool -> Bool -> (Double, Double, Int)
componentFieldPlacement cfg component field value size face bold italic =
  (centerX, centerY, relativeAngle)
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
