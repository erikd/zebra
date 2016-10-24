{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Zebra.Foreign.Block (
    CBlock(..)
  , blockOfForeign
  , foreignOfBlock

  , peekBlock
  , pokeBlock
  , peekBlockEntity
  , pokeBlockEntity
  ) where

import           Anemone.Foreign.Mempool (Mempool, alloc, calloc)

import           Control.Monad.IO.Class (MonadIO(..))

import qualified Data.ByteString as B
import qualified Data.Vector as Boxed
import qualified Data.Vector.Storable as Storable
import qualified Data.Vector.Unboxed as Unboxed

import           Foreign.Ptr (Ptr)

import           P

import           X.Control.Monad.Trans.Either (EitherT, left)

import           Zebra.Data.Block
import           Zebra.Data.Core
import           Zebra.Foreign.Bindings
import           Zebra.Foreign.Table
import           Zebra.Foreign.Util


newtype CBlock =
  CBlock {
      unCBlock :: Ptr C'zebra_block
    }

blockOfForeign :: MonadIO m => CBlock -> EitherT ForeignError m Block
blockOfForeign (CBlock c_block) =
  peekBlock c_block

foreignOfBlock :: MonadIO m => Mempool -> Block -> EitherT ForeignError m CBlock
foreignOfBlock pool block = do
  c_block <- liftIO $ alloc pool
  pokeBlock pool c_block block
  pure $ CBlock c_block

peekBlock :: MonadIO m => Ptr C'zebra_block -> EitherT ForeignError m Block
peekBlock c_block = do
  n_attrs <- peekIO $ p'zebra_block'attribute_count c_block

  n_entities <- fmap fromIntegral . peekIO $ p'zebra_block'entity_count c_block
  c_entities <- peekIO $ p'zebra_block'entities c_block
  entities <- peekMany c_entities n_entities . peekBlockEntity $ fromIntegral n_attrs

  n_rows <- fmap fromIntegral . peekIO $ p'zebra_block'row_count c_block
  times <- peekVector n_rows $ p'zebra_block'times c_block
  priorities <- peekVector n_rows $ p'zebra_block'priorities c_block
  tombstones <- peekVector n_rows $ p'zebra_block'tombstones c_block

  let
    indices =
      Unboxed.zipWith3 BlockIndex
        (Storable.convert $ timesOfForeign times)
        (Storable.convert $ prioritiesOfForeign priorities)
        (Storable.convert $ tombstonesOfForeign tombstones)

  c_tables <- peekIO $ p'zebra_block'tables c_block
  tables <- peekMany c_tables n_attrs peekTable

  pure $ Block entities indices tables

pokeBlock :: MonadIO m => Mempool -> Ptr C'zebra_block -> Block -> EitherT ForeignError m ()
pokeBlock pool c_block (Block entities indices tables) = do
  let
    n_attrs =
      Boxed.length tables

    n_entities =
      Boxed.length entities

  c_entities <- liftIO . calloc pool $ fromIntegral n_entities

  pokeIO (p'zebra_block'attribute_count c_block) $ fromIntegral n_attrs
  pokeIO (p'zebra_block'entity_count c_block) $ fromIntegral n_entities
  pokeIO (p'zebra_block'entities c_block) c_entities
  pokeMany c_entities entities $ pokeBlockEntity pool n_attrs

  let
    n_rows =
      Unboxed.length indices

    times =
      foreignOfTimes .
      Storable.convert $
      Unboxed.map indexTime indices

    priorities =
      foreignOfPriorities .
      Storable.convert $
      Unboxed.map indexPriority indices

    tombstones =
      foreignOfTombstones .
      Storable.convert $
      Unboxed.map indexTombstone indices

  pokeIO (p'zebra_block'row_count c_block) $ fromIntegral n_rows
  pokeVector pool (p'zebra_block'times c_block) times
  pokeVector pool (p'zebra_block'priorities c_block) priorities
  pokeVector pool (p'zebra_block'tombstones c_block) tombstones

  c_tables <- liftIO . calloc pool $ fromIntegral n_attrs

  pokeIO (p'zebra_block'tables c_block) c_tables
  pokeMany c_tables tables $ pokeTable pool

peekBlockEntity :: MonadIO m => Int -> Ptr C'zebra_block_entity -> m BlockEntity
peekBlockEntity n_attrs c_entity = do
  hash <- fmap EntityHash . peekIO $ p'zebra_block_entity'hash c_entity
  eid_len <- fmap fromIntegral . peekIO $ p'zebra_block_entity'id_length c_entity
  eid <- fmap EntityId . peekByteString eid_len $ p'zebra_block_entity'id_bytes c_entity

  attr_ids <- fmap attributeIdsOfForeign . peekVector n_attrs $ p'zebra_block_entity'attribute_ids c_entity
  attr_counts <- peekVector n_attrs $ p'zebra_block_entity'attribute_row_counts c_entity

  let
    attrs =
      Unboxed.zipWith BlockAttribute
        (Storable.convert attr_ids)
        (Storable.convert attr_counts)

  pure $ BlockEntity hash eid attrs

pokeBlockEntity :: MonadIO m => Mempool -> Int -> Ptr C'zebra_block_entity -> BlockEntity -> EitherT ForeignError m ()
pokeBlockEntity pool n_attrs0 c_entity (BlockEntity hash eid attrs) = do
  let
    n_attrs =
      Unboxed.length attrs

  when (n_attrs0 /= n_attrs) .
    left $ ForeignInvalidAttributeCount n_attrs0 n_attrs

  let
    eid_len =
      B.length $ unEntityId eid

  pokeIO (p'zebra_block_entity'hash c_entity) $ unEntityHash hash
  pokeIO (p'zebra_block_entity'id_length c_entity) $ fromIntegral eid_len
  pokeByteString pool (p'zebra_block_entity'id_bytes c_entity) $ unEntityId eid

  let
    attr_ids =
      foreignOfAttributeIds .
      Storable.convert $
      Unboxed.map attributeId attrs

    attr_counts =
      Storable.convert $
      Unboxed.map attributeRows attrs

  pokeVector pool (p'zebra_block_entity'attribute_ids c_entity) attr_ids
  pokeVector pool (p'zebra_block_entity'attribute_row_counts c_entity) attr_counts
