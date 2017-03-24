{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE TemplateHaskell #-}
module Test.Zebra.JSON.Schema where

import           Disorder.Jack (Property, quickCheckAll)
import           Disorder.Jack (gamble, tripping)

import           P

import           System.IO (IO)

import           Test.Zebra.Jack

import           Zebra.JSON.Schema


prop_roundtrip_schema :: Property
prop_roundtrip_schema =
  gamble jTableSchema $
    tripping encodeSchema decodeSchema

return []
tests :: IO Bool
tests =
  $quickCheckAll