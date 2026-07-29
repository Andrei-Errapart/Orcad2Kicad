-- Copyright (C) 2026 Andrei Errapart
-- SPDX-License-Identifier: GPL-2.0-or-later

-- | The Library stream: the deduplicated string pool that holds component
-- values and title-block fields, and the 60-byte style records.  Strings come
-- out as raw bytes because the pool's codepage is not known until Encoding's
-- detector has seen them.
module Dsn.Library
  ( libraryRawStrings
  , libraryFaceNameBytes
  , parseLibraryValueStrings
  , parseLibraryTextStyles
  ) where

import Binary
import Control.Monad (guard)
import qualified Data.ByteString as BS
import Data.Maybe (fromMaybe)
import Encoding (SourceEncoding, decodeLibraryString)
import Model (TextStyle(..))

parseLibraryTextStyles :: BS.ByteString -> [TextStyle]
parseLibraryTextStyles body = go 0
  where
    go idx
      | idx + 60 > BS.length body = []
      | isStyleStart idx = case parseAt idx of
          Just style -> style : go (idx + 60)
          Nothing -> go (idx + 1)
      | otherwise = go (idx + 1)

    isStyleStart idx =
      case [byteAt body (idx + offset) | offset <- [0..3]] of
        [Just b0, Just 0xff, Just 0xff, Just 0xff] -> b0 >= 0x80
        _ -> False

    parseAt idx = do
      tag <- int32LE body idx
      escapement <- int32LE body (idx + 8)
      weight <- fromIntegral <$> word32LE body (idx + 16)
      italic <- (== 0xff) <$> byteAt body (idx + 20)
      let face = asciiPrefixAt body (idx + 28) 30
      pure TextStyle
        { textStyleTag = tag
        , textStyleWeight = weight
        , textStyleItalic = italic
        , textStyleEscapement = escapement
        , textStyleFace = face
        }

-- | Raw font face names carrying high bytes.  Mirrors the 60-byte style-record
-- stride of `parseLibraryTextStyles`, but keeps the bytes: the face name is the
-- one place a design reliably names its own script.
libraryFaceNameBytes :: BS.ByteString -> [BS.ByteString]
libraryFaceNameBytes body = unique (go 0)
  where
    go idx
      | idx + 60 > BS.length body = []
      | isStyleStart idx =
          let name = BS.takeWhile (/= 0) (BS.take 30 (BS.drop (idx + 28) body))
          in [name | BS.any (>= 0x80) name] ++ go (idx + 60)
      | otherwise = go (idx + 1)

    isStyleStart idx =
      case [byteAt body (idx + offset) | offset <- [0 .. 3]] of
        [Just b0, Just 0xff, Just 0xff, Just 0xff] -> b0 >= 0x80
        _ -> False

parseLibraryValueStrings :: SourceEncoding -> BS.ByteString -> [String]
parseLibraryValueStrings enc =
  map (decodeLibraryString enc) . libraryRawStrings

libraryRawStrings :: BS.ByteString -> [BS.ByteString]
libraryRawStrings body = fromMaybe [] $ do
  textFontCount <- fromIntegral <$> word16LE body 48
  let afterFonts = 50 + max 0 (textFontCount - 1) * 60
  extraCount <- fromIntegral <$> word16LE body afterFonts
  let mappingsStart = afterFonts + 2 + extraCount * 2 + 8
  (afterMappings, _) <- readLengthStrings body mappingsStart 8
  let stringCountAt = afterMappings + 156
  count32 <- word32LE body stringCountAt
  let stringCount = fromIntegral count32 :: Int
  -- The count is a plain u32.  Reading it as a u16 (as an earlier
  -- revision did for counts above 10000) shifts every pool index by one
  -- and silently drops the whole table on large designs, because the
  -- sanity cap then rejects it.
  guard (stringCount >= 0 && stringCount <= 200000)
  snd <$> readLengthStrings body (stringCountAt + 4) stringCount

-- Kept as raw bytes: the pool's encoding is not known until
-- `detectSourceEncoding` has seen these strings.
readLengthStrings
  :: BS.ByteString -> Int -> Int -> Maybe (Int, [BS.ByteString])
readLengthStrings body = go []
  where
    go values pos 0 = Just (pos, reverse values)
    go values pos remaining = do
      stringLen <- fromIntegral <$> word16LE body pos
      guard (stringLen >= 0 && pos + 2 + stringLen <= BS.length body)
      let stringStart = pos + 2
          raw = BS.take stringLen (BS.drop stringStart body)
          afterString = stringStart + stringLen
          nextPos = if byteAt body afterString == Just 0
              then afterString + 1
              else afterString
      go (raw : values) nextPos (remaining - 1)

