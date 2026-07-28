-- Copyright (C) 2026 Andrei Errapart
-- SPDX-License-Identifier: GPL-2.0-or-later

-- | Byte patterns that delimit records in DSN streams, and the cell-name
-- scan built on them.  Shared by the page, cache and library parsers, so it
-- sits below all three rather than with any one of them.
module Dsn.Record
  ( recordMarker, netTableAnchor, textRecordType
  , pageRectTag, pageLineTag, pageEllipseTag, pagePolygonTag
  , findCellMatches, isCellChar
  ) where

import Binary (byteAt, findAll)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Char (isAlphaNum)
import Data.List (sortOn)
import Data.Word (Word8)

recordMarker :: BS.ByteString
recordMarker = BS.pack [0xff, 0xe4, 0x5c, 0x39]

netTableAnchor :: BS.ByteString
netTableAnchor = BS.pack
  [0x30, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00]

textRecordType :: BS.ByteString
textRecordType = BS.pack [0x01, 0x00, 0x2e, 0x2e]

pageRectTag, pageLineTag, pageEllipseTag, pagePolygonTag :: BS.ByteString
pageRectTag = BS.pack [0x01, 0x00, 0x28, 0x28, 0x28, 0x00]
pageLineTag = BS.pack [0x01, 0x00, 0x29, 0x29, 0x20, 0x00]
pageEllipseTag = BS.pack [0x01, 0x00, 0x2b, 0x2b, 0x28, 0x00]
pagePolygonTag = BS.pack [0x01, 0x00, 0x2c, 0x2c, 0x2e, 0x00]

findCellMatches :: BS.ByteString -> [(Int, Int, String)]
findCellMatches body =
  sortOn (\(start, _, _) -> start) $
    findForToken (BSC.pack ".Normal\0") ++ findForToken (BSC.pack ".Convert\0")
  where
    findForToken token =
      [ (cellStart, tokenPos + BS.length token, BSC.unpack (BS.take (tokenPos - cellStart) (BS.drop cellStart body)))
      | tokenPos <- findAll token body
      , let cellStart = rewindCellName tokenPos
      , cellStart < tokenPos
      ]

    rewindCellName pos
      | pos <= 0 = 0
      | otherwise =
          case byteAt body (pos - 1) of
            Just b | isCellChar b -> rewindCellName (pos - 1)
            _ -> pos

isCellChar :: Word8 -> Bool
isCellChar b =
  let c = toEnum (fromIntegral b) :: Char
  in isAlphaNum c || c `elem` ("_./+#-()" :: String)
