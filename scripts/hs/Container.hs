-- Copyright (C) 2026 Andrei Errapart
-- SPDX-License-Identifier: GPL-2.0-or-later

-- | Reading the two container formats a .DSN can arrive in: an OLE compound
-- document, or a ZIP whose members are the same streams (olefile is
-- read-only, so synthetic fixtures are authored as ZIPs).
module Container
  ( parseOleStreams
  , parseStoredZip
  , isZipArchive
  , ZipMember(..)
  ) where

import Binary
import Data.Bits ((.&.))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.List (intercalate)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import Data.Word (Word8, Word32)
import Encoding (decodeUtf16LeName)

data ZipMember = ZipMember FilePath BS.ByteString
  deriving Show

data DirEntry = DirEntry
  { dirName :: String
  , dirType :: Word8
  , dirLeft :: Maybe Int
  , dirRight :: Maybe Int
  , dirChild :: Maybe Int
  , dirStartSector :: Word32
  , dirStreamSize :: Int
  }
  deriving Show

data OleFile = OleFile
  { oleBytes :: BS.ByteString
  , oleSectorSize :: Int
  , oleMiniSectorSize :: Int
  , oleMiniCutoff :: Int
  , oleFat :: Map.Map Int Word32
  , oleMiniFat :: Map.Map Int Word32
  , oleMiniStream :: BS.ByteString
  , oleDirectory :: [DirEntry]
  }
  deriving Show

isZipArchive :: BS.ByteString -> Bool
isZipArchive = BS.isPrefixOf (BS.pack [0x50, 0x4b, 0x03, 0x04])

parseStoredZip :: BS.ByteString -> Either String [ZipMember]
parseStoredZip bytes = go 0 []
  where
    go off acc
      | off + 4 > BS.length bytes = Right (reverse acc)
      | u32 off == Just 0x04034b50 = do
          flags <- need "ZIP flags" (u16 (off + 6))
          compression <- need "ZIP compression method" (u16 (off + 8))
          compressedSize <- need "ZIP compressed size" (u32 (off + 18))
          nameLen <- need "ZIP filename length" (u16 (off + 26))
          extraLen <- need "ZIP extra length" (u16 (off + 28))
          let dataStart =
                off + 30 + fromIntegral nameLen + fromIntegral extraLen
              dataEnd = dataStart + fromIntegral compressedSize
              nameStart = off + 30
              nameEnd = nameStart + fromIntegral nameLen
          unlessEither (flags .&. 0x0008 == 0) $
            "ZIP data descriptors are not supported by the native Haskell reader"
          unlessEither (compression == 0) $
            "only stored ZIP members are supported by the native Haskell reader"
          unlessEither (dataEnd <= BS.length bytes && nameEnd <= BS.length bytes) $
            "truncated ZIP member"
          let name = BSC.unpack (BS.take (fromIntegral nameLen) (BS.drop nameStart bytes))
              body = BS.take (fromIntegral compressedSize) (BS.drop dataStart bytes)
          go dataEnd (ZipMember name body : acc)
      | otherwise = Right (reverse acc)

    u16 = word16LE bytes
    u32 = word32LE bytes

oleMagic :: BS.ByteString
oleMagic = BS.pack [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]

maxRegularSector, endOfChain, noStream :: Word32
maxRegularSector = 0xfffffffa
endOfChain = 0xfffffffe
noStream = 0xffffffff

parseOleStreams :: BS.ByteString -> Either String [(FilePath, BS.ByteString)]
parseOleStreams bytes = do
  ole <- parseOleFile bytes
  collectOleStreams ole

parseOleFile :: BS.ByteString -> Either String OleFile
parseOleFile bytes = do
  unlessEither (BS.isPrefixOf oleMagic bytes) "not an OLE compound document"
  sectorShift <- need "OLE sector shift" (word16LE bytes 0x1e)
  miniSectorShift <- need "OLE mini sector shift" (word16LE bytes 0x20)
  numFatSectors <- need "OLE FAT sector count" (word32LE bytes 0x2c)
  firstDirSector <- need "OLE first directory sector" (word32LE bytes 0x30)
  miniCutoff <- need "OLE mini stream cutoff" (word32LE bytes 0x38)
  firstMiniFatSector <- need "OLE first mini FAT sector" (word32LE bytes 0x3c)
  numMiniFatSectors <- need "OLE mini FAT sector count" (word32LE bytes 0x40)
  firstDifatSector <- need "OLE first DIFAT sector" (word32LE bytes 0x44)
  numDifatSectors <- need "OLE DIFAT sector count" (word32LE bytes 0x48)

  unlessEither (sectorShift == 9 || sectorShift == 12) $
    "unsupported OLE sector size shift: " ++ show sectorShift
  unlessEither (miniSectorShift == 6) $
    "unsupported OLE mini sector size shift: " ++ show miniSectorShift

  let sectorSize = 2 ^ (fromIntegral sectorShift :: Int)
      miniSectorSize = 2 ^ (fromIntegral miniSectorShift :: Int)
      headerFatSectors =
        filter isRegularSector
          [ sid
          | i <- [0 .. 108]
          , Just sid <- [word32LE bytes (0x4c + i * 4)]
          ]
  difatSectors <- parseDifatSectors bytes sectorSize firstDifatSector numDifatSectors
  let fatSectorIds =
        take (fromIntegral numFatSectors) (headerFatSectors ++ difatSectors)
  unlessEither (length fatSectorIds == fromIntegral numFatSectors) $
    "truncated OLE FAT sector list"
  fatEntries <- concat <$> mapM (sectorWords bytes sectorSize) fatSectorIds
  let fat = Map.fromList (zip [0..] fatEntries)

  dirBytes <- readSectorChainBytes bytes sectorSize fat firstDirSector
  dirs <- parseDirectoryEntries dirBytes
  root <- directoryEntryAt dirs 0
  miniFatBytes <-
    if numMiniFatSectors == 0 || not (isRegularSector firstMiniFatSector)
      then Right BS.empty
      else readSectorChainBytesLimit
             bytes sectorSize fat firstMiniFatSector (fromIntegral numMiniFatSectors)
  let miniFat = Map.fromList (zip [0..] (words32LE miniFatBytes))
  miniStream <-
    if dirStreamSize root == 0 || not (isRegularSector (dirStartSector root))
      then Right BS.empty
      else readSectorChainBytesTake
             bytes sectorSize fat (dirStartSector root) (dirStreamSize root)

  Right OleFile
    { oleBytes = bytes
    , oleSectorSize = sectorSize
    , oleMiniSectorSize = miniSectorSize
    , oleMiniCutoff = fromIntegral miniCutoff
    , oleFat = fat
    , oleMiniFat = miniFat
    , oleMiniStream = miniStream
    , oleDirectory = dirs
    }

parseDifatSectors
  :: BS.ByteString -> Int -> Word32 -> Word32 -> Either String [Word32]
parseDifatSectors bytes sectorSize firstSector count = go firstSector count []
  where
    entriesPerSector = sectorSize `div` 4 - 1

    go _ 0 acc = Right (reverse acc)
    go sid remaining acc
      | not (isRegularSector sid) = Left "truncated OLE DIFAT chain"
      | otherwise = do
          sector <- need "OLE DIFAT sector" (readSector bytes sectorSize sid)
          let wordsInSector = words32LE sector
              entries = take entriesPerSector wordsInSector
              nextSid =
                fromMaybe endOfChain $
                  word32LE sector (sectorSize - 4)
          go nextSid (remaining - 1) (reverse (filter isRegularSector entries) ++ acc)

sectorWords :: BS.ByteString -> Int -> Word32 -> Either String [Word32]
sectorWords bytes sectorSize sid = do
  sector <- need ("OLE sector " ++ show sid) (readSector bytes sectorSize sid)
  Right (words32LE sector)

parseDirectoryEntries :: BS.ByteString -> Either String [DirEntry]
parseDirectoryEntries bytes =
  mapM parseEntry [0, 128 .. BS.length bytes - 128]
  where
    parseEntry off = do
      entry <- need "OLE directory entry" (sliceAt bytes off 128)
      nameLen <- need "OLE directory name length" (word16LE entry 64)
      objectType <- need "OLE directory object type" (byteAt entry 66)
      leftSid <- need "OLE left sibling id" (word32LE entry 68)
      rightSid <- need "OLE right sibling id" (word32LE entry 72)
      childSid <- need "OLE child id" (word32LE entry 76)
      startSector <- need "OLE stream start sector" (word32LE entry 116)
      size64 <- need "OLE stream size" (word64LE entry 120)
      size <- word64ToInt "OLE stream size" size64
      let usableNameBytes
            | nameLen >= 2 && nameLen <= 64 = fromIntegral nameLen - 2
            | otherwise = 0
          name = decodeUtf16LeName (BS.take usableNameBytes entry)
      Right DirEntry
        { dirName = name
        , dirType = objectType
        , dirLeft = sidToMaybe leftSid
        , dirRight = sidToMaybe rightSid
        , dirChild = sidToMaybe childSid
        , dirStartSector = startSector
        , dirStreamSize = size
        }

collectOleStreams :: OleFile -> Either String [(FilePath, BS.ByteString)]
collectOleStreams ole = do
  root <- directoryEntryAt (oleDirectory ole) 0
  (_, streams) <- collectChildren (Set.singleton 0) [] (dirChild root)
  Right streams
  where
    collectChildren seen _ Nothing = Right (seen, [])
    collectChildren seen prefix (Just sid)
      | Set.member sid seen =
          Left ("OLE directory entry cycle at SID " ++ show sid)
      | otherwise = do
          entry <- directoryEntryAt (oleDirectory ole) sid
          let seen' = Set.insert sid seen
          (afterLeft, left) <- collectChildren seen' prefix (dirLeft entry)
          (afterCurrent, current) <- collectEntry afterLeft prefix entry
          (afterRight, right) <-
            collectChildren afterCurrent prefix (dirRight entry)
          Right (afterRight, left ++ current ++ right)

    collectEntry seen prefix entry
      | dirType entry == 1 =
          collectChildren seen (prefix ++ [dirName entry]) (dirChild entry)
      | dirType entry == 5 = collectChildren seen prefix (dirChild entry)
      | dirType entry == 2 = do
          body <- readOleStream ole entry
          Right (seen, [(intercalate "/" (prefix ++ [dirName entry]), body)])
      | otherwise = Right (seen, [])

readOleStream :: OleFile -> DirEntry -> Either String BS.ByteString
readOleStream ole entry
  | dirStreamSize entry == 0 = Right BS.empty
  | dirStreamSize entry < oleMiniCutoff ole =
      readMiniSectorChainBytesTake
        (oleMiniStream ole)
        (oleMiniSectorSize ole)
        (oleMiniFat ole)
        (dirStartSector entry)
        (dirStreamSize entry)
  | otherwise =
      readSectorChainBytesTake
        (oleBytes ole)
        (oleSectorSize ole)
        (oleFat ole)
        (dirStartSector entry)
        (dirStreamSize entry)

directoryEntryAt :: [DirEntry] -> Int -> Either String DirEntry
directoryEntryAt entries sid
  | sid >= 0 && sid < length entries = Right (entries !! sid)
  | otherwise = Left ("OLE directory SID out of range: " ++ show sid)

readSectorChainBytes
  :: BS.ByteString -> Int -> Map.Map Int Word32 -> Word32 -> Either String BS.ByteString
readSectorChainBytes bytes sectorSize fat startSid = do
  chain <- sectorChain fat startSid
  sectors <- mapM (need "OLE chained sector" . readSector bytes sectorSize) chain
  Right (BS.concat sectors)

readSectorChainBytesLimit
  :: BS.ByteString
  -> Int
  -> Map.Map Int Word32
  -> Word32
  -> Int
  -> Either String BS.ByteString
readSectorChainBytesLimit bytes sectorSize fat startSid limit = do
  chain <- take limit <$> sectorChain fat startSid
  sectors <- mapM (need "OLE chained sector" . readSector bytes sectorSize) chain
  Right (BS.concat sectors)

readSectorChainBytesTake
  :: BS.ByteString -> Int -> Map.Map Int Word32 -> Word32 -> Int -> Either String BS.ByteString
readSectorChainBytesTake bytes sectorSize fat startSid size = do
  body <- readSectorChainBytes bytes sectorSize fat startSid
  unlessEither (BS.length body >= size) "truncated OLE stream chain"
  Right (BS.take size body)

readMiniSectorChainBytesTake
  :: BS.ByteString -> Int -> Map.Map Int Word32 -> Word32 -> Int -> Either String BS.ByteString
readMiniSectorChainBytesTake miniStream miniSectorSize miniFat startSid size = do
  chain <- sectorChain miniFat startSid
  sectors <- mapM readMiniSector chain
  let body = BS.concat sectors
  unlessEither (BS.length body >= size) "truncated OLE mini stream chain"
  Right (BS.take size body)
  where
    readMiniSector sid = do
      sidInt <- word32ToInt "OLE mini sector id" sid
      let start = sidInt * miniSectorSize
      need "OLE mini sector" (sliceAt miniStream start miniSectorSize)

sectorChain :: Map.Map Int Word32 -> Word32 -> Either String [Word32]
sectorChain table startSid = go Map.empty [] startSid
  where
    -- Termination rests on `seen`: every visited sector is recorded, and a
    -- sector missing from the FAT ends the walk, so the chain cannot outrun the
    -- table.  An additional length check would be redundant and, because it
    -- measured the accumulator, quadratic in the chain length.
    go seen acc sid
      | sid == endOfChain = Right (reverse acc)
      | not (isRegularSector sid) =
          Left ("unexpected OLE sector marker in chain: " ++ showHex32 sid)
      | Map.member (fromIntegral sid :: Int) seen = Left "OLE sector chain cycle"
      | otherwise = do
          sidInt <- word32ToInt "OLE sector id" sid
          next <- need ("OLE FAT entry for sector " ++ show sidInt) (Map.lookup sidInt table)
          go (Map.insert sidInt () seen) (sid : acc) next

readSector :: BS.ByteString -> Int -> Word32 -> Maybe BS.ByteString
readSector bytes sectorSize sid = do
  sidInt <- maybeWord32ToInt sid
  let start = (sidInt + 1) * sectorSize
  sliceAt bytes start sectorSize

sidToMaybe :: Word32 -> Maybe Int
sidToMaybe sid
  | sid == noStream = Nothing
  | otherwise = maybeWord32ToInt sid

isRegularSector :: Word32 -> Bool
isRegularSector sid = sid <= maxRegularSector

