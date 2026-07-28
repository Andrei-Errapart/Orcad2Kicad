-- Copyright (C) 2026 Andrei Errapart
-- SPDX-License-Identifier: GPL-2.0-or-later

-- | UTF-8 encoding, kept dependency-free so both the UUID seed and the file
-- writer can use it without pulling in codepage handling.
module Utf8 (utf8Encode) where

import Data.Bits ((.&.), (.|.), shiftR)
import qualified Data.ByteString as BS
import Data.Char (ord)
import Data.Word (Word8)

utf8Encode :: String -> BS.ByteString
utf8Encode = BS.pack . concatMap encodeChar
  where
    encodeChar :: Char -> [Word8]
    encodeChar char
      | code <= 0x7f =
          [fromIntegral code]
      | code <= 0x7ff =
          [ fromIntegral (0xc0 .|. (code `shiftR` 6))
          , fromIntegral (0x80 .|. (code .&. 0x3f))
          ]
      | code >= 0xd800 && code <= 0xdfff =
          encodeCodePoint 0xfffd
      | code <= 0xffff =
          encodeCodePoint code
      | otherwise =
          [ fromIntegral (0xf0 .|. (code `shiftR` 18))
          , fromIntegral (0x80 .|. ((code `shiftR` 12) .&. 0x3f))
          , fromIntegral (0x80 .|. ((code `shiftR` 6) .&. 0x3f))
          , fromIntegral (0x80 .|. (code .&. 0x3f))
          ]
      where
        code = ord char

    encodeCodePoint :: Int -> [Word8]
    encodeCodePoint code =
      [ fromIntegral (0xe0 .|. (code `shiftR` 12))
      , fromIntegral (0x80 .|. ((code `shiftR` 6) .&. 0x3f))
      , fromIntegral (0x80 .|. (code .&. 0x3f))
      ]
