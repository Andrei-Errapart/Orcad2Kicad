-- Copyright (C) 2026 Andrei Errapart
-- SPDX-License-Identifier: GPL-2.0-or-later

-- | Bounds-checked byte accessors over a strict ByteString, plus the small
-- list and Maybe helpers the parsers share.  Every accessor returns Maybe
-- rather than throwing, which is what keeps the parsers total.
module Binary
  ( byteAt, word16LE, word32LE, word64LE, int16LE, int32LE
  , sliceAt, words32LE, readI32Quad, readI32Oct
  , findSubFrom, findSubBefore, findAll, findAllFrom
  , asciiAt, asciiPrefixAt, isPrintableAscii, extractStrings
  , word64ToInt, word32ToInt, maybeWord32ToInt, showHex32
  , need, unlessEither, firstJust, lookupList, listAt, orElse
  , unique, splitSlash, stripStringPrefix, dedupeConsecutive
  , commonStringPrefix, trimTrailingUnderscores
  ) where

import Control.Monad (guard)
import Data.Bits ((.&.))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Int (Int16, Int32)
import qualified Data.Map.Strict as Map
import Data.Word (Word8, Word16, Word32, Word64)

splitSlash :: String -> [String]
splitSlash = splitOn '/'

splitOn :: Char -> String -> [String]
splitOn separator value =
  case break (== separator) value of
    (part, []) -> [part]
    (part, _:rest) -> part : splitOn separator rest

sliceAt :: BS.ByteString -> Int -> Int -> Maybe BS.ByteString
sliceAt bytes start size
  | start >= 0 && size >= 0 && start + size <= BS.length bytes =
      Just (BS.take size (BS.drop start bytes))
  | otherwise = Nothing

words32LE :: BS.ByteString -> [Word32]
words32LE bytes =
  [value | off <- [0, 4 .. BS.length bytes - 4], Just value <- [word32LE bytes off]]

word64ToInt :: String -> Word64 -> Either String Int
word64ToInt label value
  | value <= fromIntegral (maxBound :: Int) = Right (fromIntegral value)
  | otherwise = Left (label ++ " too large")

word32ToInt :: String -> Word32 -> Either String Int
word32ToInt label value =
  maybe (Left (label ++ " too large")) Right (maybeWord32ToInt value)

maybeWord32ToInt :: Word32 -> Maybe Int
maybeWord32ToInt value
  | fromIntegral value <= (maxBound :: Int) = Just (fromIntegral value)
  | otherwise = Nothing

showHex32 :: Word32 -> String
showHex32 value =
  let digits = "0123456789abcdef"
      nybble :: Int -> Char
      nybble shift = digits !! fromIntegral ((value `div` (16 ^ shift)) .&. 0xf)
  in "0x" ++ [nybble s | s <- [7,6..0 :: Int]]

need :: String -> Maybe a -> Either String a
need label = maybe (Left ("missing " ++ label)) Right

unlessEither :: Bool -> String -> Either String ()
unlessEither True _ = Right ()
unlessEither False err = Left err

stripStringPrefix :: String -> String -> Maybe String
stripStringPrefix [] value = Just value
stripStringPrefix _ [] = Nothing
stripStringPrefix (expected:prefix) (actual:value)
  | expected == actual = stripStringPrefix prefix value
  | otherwise = Nothing

commonStringPrefix :: [String] -> String
commonStringPrefix [] = ""
commonStringPrefix (first:rest) = foldl commonPrefix first rest
  where
    commonPrefix left right = map fst $ takeWhile (uncurry (==)) (zip left right)

trimTrailingUnderscores :: String -> String
trimTrailingUnderscores = reverse . dropWhile (== '_') . reverse

dedupeConsecutive :: Eq a => [a] -> [a]
dedupeConsecutive [] = []
dedupeConsecutive (x:xs) = x : go x xs
  where
    go _ [] = []
    go prev (value:rest)
      | value == prev = go prev rest
      | otherwise = value : go value rest

unique :: Ord a => [a] -> [a]
unique = go Map.empty
  where
    go _ [] = []
    go seen (x:xs)
      | Map.member x seen = go seen xs
      | otherwise = x : go (Map.insert x () seen) xs

extractStrings :: BS.ByteString -> Int -> [(Int, String)]
extractStrings body minLen = finish (BS.length body) [] [] 0 (BS.unpack body)
  where
    finish _pos acc current start [] =
      let acc' = if length current >= minLen then (start, reverse current) : acc else acc
      in reverse acc'
    finish pos acc current start (b:bs)
      | isPrintableAscii b =
          let start' = if null current then pos else start
          in finish (pos + 1) acc (byteToChar b : current) start' bs
      | otherwise =
          let acc' = if length current >= minLen then (start, reverse current) : acc else acc
          in finish (pos + 1) acc' [] (pos + 1) bs

asciiAt :: BS.ByteString -> Int -> Int -> Maybe String
asciiAt body off len = do
  guard (off >= 0 && len >= 0 && off + len <= BS.length body)
  let chunk = BS.take len (BS.drop off body)
  guard (BS.all isPrintableAscii chunk)
  pure (BSC.unpack chunk)

asciiPrefixAt :: BS.ByteString -> Int -> Int -> String
asciiPrefixAt body off maxLen =
  BSC.unpack $ BS.takeWhile isPrintableAscii $ BS.take maxLen $ BS.drop off body

isPrintableAscii :: Word8 -> Bool
isPrintableAscii b = b >= 32 && b < 127

byteToChar :: Word8 -> Char
byteToChar = toEnum . fromIntegral

byteAt :: BS.ByteString -> Int -> Maybe Word8
byteAt body off
  | off >= 0 && off < BS.length body = Just (BS.index body off)
  | otherwise = Nothing

word16LE :: BS.ByteString -> Int -> Maybe Word16
word16LE body off = do
  b0 <- byteAt body off
  b1 <- byteAt body (off + 1)
  pure $ fromIntegral b0 + fromIntegral b1 * 0x100

word32LE :: BS.ByteString -> Int -> Maybe Word32
word32LE body off = do
  b0 <- byteAt body off
  b1 <- byteAt body (off + 1)
  b2 <- byteAt body (off + 2)
  b3 <- byteAt body (off + 3)
  pure $
    fromIntegral b0
    + fromIntegral b1 * 0x100
    + fromIntegral b2 * 0x10000
    + fromIntegral b3 * 0x1000000

word64LE :: BS.ByteString -> Int -> Maybe Word64
word64LE body off = do
  b0 <- byteAt body off
  b1 <- byteAt body (off + 1)
  b2 <- byteAt body (off + 2)
  b3 <- byteAt body (off + 3)
  b4 <- byteAt body (off + 4)
  b5 <- byteAt body (off + 5)
  b6 <- byteAt body (off + 6)
  b7 <- byteAt body (off + 7)
  pure $
    fromIntegral b0
    + fromIntegral b1 * 0x100
    + fromIntegral b2 * 0x10000
    + fromIntegral b3 * 0x1000000
    + fromIntegral b4 * 0x100000000
    + fromIntegral b5 * 0x10000000000
    + fromIntegral b6 * 0x1000000000000
    + fromIntegral b7 * 0x100000000000000

int16LE :: BS.ByteString -> Int -> Maybe Int
int16LE body off = fromIntegral . (fromIntegral :: Word16 -> Int16) <$> word16LE body off

int32LE :: BS.ByteString -> Int -> Maybe Int
int32LE body off = fromIntegral . (fromIntegral :: Word32 -> Int32) <$> word32LE body off

readI32Quad :: BS.ByteString -> Int -> Maybe (Int, Int, Int, Int)
readI32Quad body off = do
  x1 <- int32LE body off
  y1 <- int32LE body (off + 4)
  x2 <- int32LE body (off + 8)
  y2 <- int32LE body (off + 12)
  pure (x1, y1, x2, y2)

readI32Oct :: BS.ByteString -> Int -> Maybe (Int, Int, Int, Int, Int, Int, Int, Int)
readI32Oct body off = do
  x1 <- int32LE body off
  y1 <- int32LE body (off + 4)
  x2 <- int32LE body (off + 8)
  y2 <- int32LE body (off + 12)
  x3 <- int32LE body (off + 16)
  y3 <- int32LE body (off + 20)
  x4 <- int32LE body (off + 24)
  y4 <- int32LE body (off + 28)
  pure (x1, y1, x2, y2, x3, y3, x4, y4)

findSubFrom :: BS.ByteString -> Int -> BS.ByteString -> Maybe Int
findSubFrom needle start haystack
  | BS.null needle = Just start
  | start < 0 || start > BS.length haystack = Nothing
  | otherwise =
      let (before, after) = BS.breakSubstring needle (BS.drop start haystack)
      in if BS.null after
         then Nothing
         else Just (start + BS.length before)

findSubBefore :: BS.ByteString -> Int -> Int -> BS.ByteString -> Maybe Int
findSubBefore needle start end haystack = do
  idx <- findSubFrom needle start haystack
  guard (idx < end)
  pure idx

findAll :: BS.ByteString -> BS.ByteString -> [Int]
findAll needle = findAllFrom needle 0

findAllFrom :: BS.ByteString -> Int -> BS.ByteString -> [Int]
findAllFrom needle start haystack =
  case findSubFrom needle start haystack of
    Nothing -> []
    Just idx -> idx : findAllFrom needle (idx + 1) haystack

firstJust :: [Maybe a] -> Maybe a
firstJust [] = Nothing
firstJust (x:xs) = case x of
  Just _ -> x
  Nothing -> firstJust xs

lookupList :: [a] -> Int -> Maybe a
lookupList values index
  | index < 0 = Nothing
  | otherwise = case drop index values of
      value : _ -> Just value
      [] -> Nothing

listAt :: [a] -> Int -> Maybe a
listAt = lookupList

orElse :: Maybe a -> Maybe a -> Maybe a
orElse value@Just{} _ = value
orElse Nothing fallback = fallback
