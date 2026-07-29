-- Copyright (C) 2026 Andrei Errapart
-- SPDX-License-Identifier: GPL-2.0-or-later

-- | Building and rendering KiCad S-expressions.  Knows nothing about OrCAD;
-- fmt's four decimals are load-bearing (see the note there) because a pin's
-- page position is the sum of two separately emitted numbers.
module Sexpr
  ( KExpr(..)
  , kAtom, kString, kNode, kInt, kDouble, kRawNum
  , kNo, kYes, kAt, kUuid, kCoord, kXy
  , kStroke, kFillType, kPolylineShape, kCircleShape, kArcShape
  , kTextEffects, kStyledTextEffects, kStyledProperty
  , kColoredStroke, kPageFill, kProperty, kHiddenProperty
  , renderKicad, esc, escJson
  ) where

import Data.Char (ord)
import Data.List (isSuffixOf)
import Model (Rgba(..))
import Numeric (showFFloat)
import Orcad.Geometry (unitToMm)

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
