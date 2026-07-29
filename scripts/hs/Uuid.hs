-- Copyright (C) 2026 Andrei Errapart
-- SPDX-License-Identifier: GPL-2.0-or-later

-- | Deterministic UUIDs, seeded from the DSN digest so an edit on one page
-- never churns UUIDs on unrelated pages.
module Uuid (deterministicUuid, stableObjectUuid) where

import qualified Data.ByteString as BS
import Data.Bits ((.&.), (.|.))
import Data.List (intercalate)
import Numeric (showHex)
import Sha256 (sha256)
import Utf8 (utf8Encode)

stableObjectUuid :: BS.ByteString -> Int -> Int -> String
stableObjectUuid seed category objectIndex =
  deterministicUuid seed (show category ++ ":" ++ show objectIndex)

-- Seed every output from the DSN digest alone.  Explicit object keys include
-- stable page/stream identity, so source and output filenames need not be part
-- of the seed and renaming the input does not churn UUIDs.
deterministicUuid :: BS.ByteString -> String -> String
deterministicUuid seed objectKey =
  formatUuid $ setUuidVersionAndVariant $ BS.take 16 $
    sha256 (seed <> BS.singleton 0 <> utf8Encode objectKey)

setUuidVersionAndVariant :: BS.ByteString -> BS.ByteString
setUuidVersionAndVariant bytes = BS.pack
  [ case index of
      6 -> (value .&. 0x0f) .|. 0x40
      8 -> (value .&. 0x3f) .|. 0x80
      _ -> value
  | (index, value) <- zip [0 :: Int ..] (BS.unpack bytes)
  ]

formatUuid :: BS.ByteString -> String
formatUuid bytes =
  intercalate "-"
    [ take 8 rendered
    , take 4 (drop 8 rendered)
    , take 4 (drop 12 rendered)
    , take 4 (drop 16 rendered)
    , take 12 (drop 20 rendered)
    ]
  where
    rendered = concatMap hexByte (BS.unpack bytes)
    hexByte value =
      let digits = showHex value ""
      in replicate (2 - length digits) '0' ++ digits
