-- Copyright (C) 2026 Andrei Errapart
-- SPDX-License-Identifier: GPL-2.0-or-later

-- | Project-level emitters: the root (index) schematic, the .kicad_pro
-- stub, the sym-lib-table, and the bundled worksheet.
module Emit.Project
  ( generateRootSch, generateProject, generateSymLibTable, generateWorksheet
  ) where

import qualified Data.ByteString as BS
import Model (Page(..))
import Sexpr
  ( kAt, kDouble, kInt, kNo, kNode, kProperty, kRawNum
  , kString, kStroke, kUuid, kYes
  , renderKicad, esc, escJson
  )
import Uuid (stableObjectUuid)

generateRootSch :: BS.ByteString -> String -> [Page] -> String
generateRootSch uuidSeed project pages =
  renderKicad $
    kNode "kicad_sch" $
      [ kNode "version" [kInt 20260306]
      , kNode "generator" [kString "dsn2kicad"]
      , kNode "generator_version" [kString "0.1"]
      , kUuid (stableObjectUuid uuidSeed 0 1)
      , kNode "paper" [kString "A3"]
      , kNode "title_block" [kNode "title" [kString (project ++ " (DSN import)")]]
      , kNode "lib_symbols" []
      ]
      ++ map emitSheet (zip [(1 :: Int)..] pages)
      ++ [ kNode "sheet_instances"
             [ kNode "path" [kString "/", kNode "page" [kString "1"]]
             ]
         , kNo "embedded_fonts"
         ]
  where
    -- The index sheet is A3 (420 x 297 mm).  Columns are filled top to bottom;
    -- growing the column height before adding columns keeps wide designs on the
    -- sheet instead of running off the right edge.  At most 6 columns fit
    -- (15 + 5 * 68 + 60 = 415) and at most 15 rows (25 + 14 * 17 + 12 = 275),
    -- and the four-row default is preserved for the designs that already fit.
    maxSheetColumns, maxSheetRows :: Int
    maxSheetColumns = 6
    maxSheetRows = 15
    rowsPerColumn =
      max 4 $ min maxSheetRows $
        (length pages + maxSheetColumns - 1) `div` maxSheetColumns

    emitSheet (idx, page) =
      let row = (idx - 1) `mod` rowsPerColumn
          col = (idx - 1) `div` rowsPerColumn
          x = 15 + col * 68
          y = 25 + row * 17
      in kNode "sheet"
           [ kAt [kInt x, kInt y]
           , kNode "size" [kRawNum "60", kRawNum "12"]
           , kNo "exclude_from_sim"
           , kYes "in_bom"
           , kYes "on_board"
           , kNo "dnp"
           , kYes "fields_autoplaced"
           , kStroke "0.1524" "solid"
           , kNode "fill" [kNode "color" [kInt 0, kInt 0, kInt 0, kInt 0]]
           , kUuid (stableObjectUuid uuidSeed 4 idx)
           , kProperty
               "Sheetname"
               (pageTitle page)
               (kAt [kInt x, kDouble (fromIntegral y - 0.7), kInt 0])
           , kProperty
               "Sheetfile"
               (pageOutputName page)
               (kAt [kInt x, kDouble (fromIntegral y + 12.7), kInt 0])
           ]

generateProject :: String -> Bool -> String
generateProject project emitWorksheet =
  unlines $
    [ "{"
    , "  \"meta\": {"
    , "    \"filename\": \"" ++ escJson project ++ ".kicad_pro\","
    , "    \"version\": 2"
    , "  },"
    , "  \"schematic\": {"
    , "    \"drawing\": {},"
    , "    \"meta\": {"
    , "      \"version\": 1"
    , "    }" ++ if emitWorksheet then "," else ""
    ]
    ++ [ "    \"page_layout_descr_file\": \"" ++ escJson project ++ ".kicad_wks\""
       | emitWorksheet
       ]
    ++
    [ "  }"
    , "}"
    ]

generateSymLibTable :: String -> String
generateSymLibTable project =
  unlines
    [ "(sym_lib_table"
    , "  (version 7)"
    , "  (lib (name \"" ++ esc project ++ "\")(type \"KiCad\")(uri \"${KIPRJMOD}/" ++ esc project ++ ".kicad_sym\")(options \"\")(descr \"\"))"
    , ")"
    ]

generateWorksheet :: String
generateWorksheet =
  unlines
    [ "(page_layout"
    , "  (setup (textsize 1.5 1.5) (linewidth 0.15) (textlinewidth 0.15)"
    , "    (left_margin 0) (right_margin 0) (top_margin 0) (bottom_margin 0))"
    , "  (rect (comment \"rect around the title block\") (linewidth 0.15) (start 110 34) (end 2 2))"
    , "  (rect (start 0 0 ltcorner) (end 0 0 rbcorner) (repeat 2) (incrx 2) (incry 2))"
    , "  (line (start 50 2 ltcorner) (end 50 0 ltcorner) (repeat 30) (incrx 50))"
    , "  (tbtext \"1\" (pos 25 1 ltcorner) (font (size 1.3 1.3)) (repeat 100) (incrx 50))"
    , "  (line (start 50 2 lbcorner) (end 50 0 lbcorner) (repeat 30) (incrx 50))"
    , "  (tbtext \"1\" (pos 25 1 lbcorner) (font (size 1.3 1.3)) (repeat 100) (incrx 50))"
    , "  (line (start 0 50 ltcorner) (end 2 50 ltcorner) (repeat 30) (incry 50))"
    , "  (tbtext \"A\" (pos 1 25 ltcorner) (font (size 1.3 1.3)) (justify center) (repeat 100) (incry 50))"
    , "  (line (start 0 50 rtcorner) (end 2 50 rtcorner) (repeat 30) (incry 50))"
    , "  (tbtext \"A\" (pos 1 25 rtcorner) (font (size 1.3 1.3)) (justify center) (repeat 100) (incry 50))"
    , "  (tbtext \"Date: %D\" (pos 87 6.9))"
    , "  (line (start 110 5.5) (end 2 5.5))"
    , "  (tbtext \"%K\" (pos 109 4.1) (comment \"KiCad version\"))"
    , "  (line (start 110 8.5) (end 2 8.5))"
    , "  (tbtext \"Rev: %R\" (pos 24 6.9) (font bold) (justify left))"
    , "  (tbtext \"Size: %Z\" (comment \"Paper format name\") (pos 109 6.9))"
    , "  (tbtext \"Id: %S/%N\" (comment \"Sheet id\") (pos 24 4.1))"
    , "  (line (start 110 12.5) (end 2 12.5))"
    , "  (tbtext \"Title: %T\" (pos 109 10.7) (font bold italic (size 2 2)))"
    , "  (tbtext \"File: %F\" (pos 109 14.3))"
    , "  (line (start 110 18.5) (end 2 18.5))"
    , "  (tbtext \"Sheet: %P\" (pos 109 17))"
    , "  (tbtext \"%Y\" (comment \"Company name\") (pos 109 20) (font bold))"
    , "  (tbtext \"%C0\" (comment \"Comment 0\") (pos 109 23))"
    , "  (tbtext \"%C1\" (comment \"Comment 1\") (pos 109 26))"
    , "  (tbtext \"%C2\" (comment \"Comment 2\") (pos 109 29))"
    , "  (tbtext \"%C3\" (comment \"Comment 3\") (pos 109 32))"
    , "  (line (start 90 8.5) (end 90 5.5))"
    , "  (line (start 26 8.5) (end 26 2))"
    , ")"
    ]
