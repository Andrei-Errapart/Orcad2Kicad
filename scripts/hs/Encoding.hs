-- Copyright (C) 2026 Andrei Errapart
-- SPDX-License-Identifier: GPL-2.0-or-later

-- | Detection and decoding of the Library string pool's source codepage.
-- OrCAD writes the pool in the authoring machine's Windows ANSI codepage and
-- records which one nowhere, so it is either detected here or named on the
-- command line.
module Encoding
  ( SourceEncoding(..)
  , sourceEncodingByName, sourceEncodingNames, encodingFlagPrefix
  , decodeLibraryString, detectSourceEncoding, decodeUtf16LeName
  ) where

import Binary (word16LE)
import Codepage.Tables (Codepage(..), cp932Table, cp936Table, cp950Table, cp1252High)
import qualified Data.Array.Unboxed as U
import Data.Bits (shiftL)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Char (ord, toLower)
import Data.List (isInfixOf, sortOn)
import Data.Maybe (fromMaybe, isJust)

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

encodingFlagPrefix :: String
encodingFlagPrefix = "--source-encoding="

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
detectSourceEncoding
  :: Maybe SourceEncoding   -- ^ explicit override
  -> [BS.ByteString]        -- ^ pool strings, raw
  -> [BS.ByteString]        -- ^ font face names, raw
  -> SourceEncoding
detectSourceEncoding (Just chosen) _ _ = chosen
detectSourceEncoding Nothing poolStrings faceNames
  | null highPool && null highFaces = EncCp1252
  | not (null highPool) && all (isJust . decodeUtf8Strict) highPool = EncUtf8
  | Just best <- bestByFontName = best
  | highByteRunPercent highPool >= 75 = byContent
  | otherwise = EncCp1252
  where
    highPool = [s | s <- poolStrings, BS.any (>= 0x80) s]
    highFaces = [s | s <- faceNames, BS.any (>= 0x80) s]
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
