-- Copyright (C) 2026 Andrei Errapart
-- SPDX-License-Identifier: GPL-2.0-or-later

-- | SHA-256, used only to seed deterministic UUIDs.  No dependencies beyond
-- base and bytestring, so it stays at the bottom of the module graph.
module Sha256 (sha256) where

import Data.Array (Array, (!), array, listArray)
import Data.Bits (complement, rotateR, shiftL, shiftR, xor, (.&.), (.|.))
import qualified Data.ByteString as BS
import qualified Data.List as List
import Data.Word (Word32, Word64)

type Sha256State =
  (Word32, Word32, Word32, Word32, Word32, Word32, Word32, Word32)

sha256 :: BS.ByteString -> BS.ByteString
sha256 input = BS.concat (map word32Be finalWords)
  where
    bitLength = fromIntegral (BS.length input) * 8 :: Word64
    paddingLength = (56 - ((BS.length input + 1) `mod` 64)) `mod` 64
    padded =
      input
      <> BS.singleton 0x80
      <> BS.replicate paddingLength 0
      <> word64Be bitLength
    blocks =
      [ BS.take 64 (BS.drop offset padded)
      | offset <- [0, 64 .. BS.length padded - 64]
      ]
    initialState =
      ( 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
      , 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
      )
    finalWords = stateWords (List.foldl' compressSha256 initialState blocks)

compressSha256 :: Sha256State -> BS.ByteString -> Sha256State
compressSha256 initial block = addSha256States initial compressed
  where
    schedule :: Array Int Word32
    schedule = array (0, 63) $
      [ (index, word32BeAt block (index * 4))
      | index <- [0..15]
      ]
      ++
      [ ( index
        , smallSigma1 (schedule ! (index - 2))
          + schedule ! (index - 7)
          + smallSigma0 (schedule ! (index - 15))
          + schedule ! (index - 16)
        )
      | index <- [16..63]
      ]

    compressed = List.foldl' roundSha256 initial [0..63]
    roundSha256 (a, b, c, d, e, f, g, h) index =
      let choice = (e .&. f) `xor` (complement e .&. g)
          majority = (a .&. b) `xor` (a .&. c) `xor` (b .&. c)
          temporary1 =
            h + bigSigma1 e + choice + sha256Constants ! index
            + schedule ! index
          temporary2 = bigSigma0 a + majority
      in (temporary1 + temporary2, a, b, c, d + temporary1, e, f, g)

smallSigma0, smallSigma1, bigSigma0, bigSigma1 :: Word32 -> Word32
smallSigma0 value =
  rotateR value 7 `xor` rotateR value 18 `xor` shiftR value 3
smallSigma1 value =
  rotateR value 17 `xor` rotateR value 19 `xor` shiftR value 10
bigSigma0 value =
  rotateR value 2 `xor` rotateR value 13 `xor` rotateR value 22
bigSigma1 value =
  rotateR value 6 `xor` rotateR value 11 `xor` rotateR value 25

addSha256States :: Sha256State -> Sha256State -> Sha256State
addSha256States
  (a, b, c, d, e, f, g, h)
  (a', b', c', d', e', f', g', h') =
    (a + a', b + b', c + c', d + d', e + e', f + f', g + g', h + h')

stateWords :: Sha256State -> [Word32]
stateWords (a, b, c, d, e, f, g, h) = [a, b, c, d, e, f, g, h]

word32BeAt :: BS.ByteString -> Int -> Word32
word32BeAt bytes off =
  fromIntegral (BS.index bytes off) `shiftL` 24
  .|. fromIntegral (BS.index bytes (off + 1)) `shiftL` 16
  .|. fromIntegral (BS.index bytes (off + 2)) `shiftL` 8
  .|. fromIntegral (BS.index bytes (off + 3))

word32Be :: Word32 -> BS.ByteString
word32Be value = BS.pack
  [ fromIntegral (value `shiftR` 24)
  , fromIntegral (value `shiftR` 16)
  , fromIntegral (value `shiftR` 8)
  , fromIntegral value
  ]

word64Be :: Word64 -> BS.ByteString
word64Be value = BS.pack
  [ fromIntegral (value `shiftR` shift)
  | shift <- [56, 48 .. 0]
  ]

sha256Constants :: Array Int Word32
sha256Constants = listArray (0, 63)
  [ 0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5
  , 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5
  , 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3
  , 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174
  , 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc
  , 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da
  , 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7
  , 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967
  , 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13
  , 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85
  , 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3
  , 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070
  , 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5
  , 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3
  , 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208
  , 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
  ]
