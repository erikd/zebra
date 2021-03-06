{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Zebra.Merge.Table (
    UnionTableError(..)
  , renderUnionTableError

  , unionLogical
  , unionStriped
  , unionStripedWith
  ) where

import           Control.Monad.Morph (hoist, squash)
import           Control.Monad.Trans.Class (lift)

import           Data.Map (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Vector as Boxed

import           P

import           Viking (Stream, Of)
import qualified Viking.Stream as Stream

import           X.Control.Monad.Trans.Either (EitherT, hoistEither, left)
import           X.Data.Vector.Cons (Cons)
import qualified X.Data.Vector.Cons as Cons

import           Zebra.Table.Logical (LogicalSchemaError, LogicalMergeError)
import qualified Zebra.Table.Logical as Logical
import           Zebra.Table.Schema (SchemaUnionError)
import qualified Zebra.Table.Schema as Schema
import           Zebra.Table.Striped (StripedError)
import qualified Zebra.Table.Striped as Striped


data Input m =
  Input {
      inputData :: !(Map Logical.Value Logical.Value)
    , inputStream :: !(Maybe (Stream (Of Logical.Table) m ()))
    }

data Step m =
  Step {
      _stepComplete :: !(Map Logical.Value Logical.Value)
    , _stepRemaining :: !(Cons Boxed.Vector (Input m))
    }

data UnionTableError =
    UnionEmptyInput
  | UnionStripedError !StripedError
  | UnionLogicalSchemaError !LogicalSchemaError
  | UnionLogicalMergeError !LogicalMergeError
  | UnionSchemaError !SchemaUnionError
    deriving (Eq, Show)

renderUnionTableError :: UnionTableError -> Text
renderUnionTableError = \case
  UnionEmptyInput ->
    "Cannot merge empty files"
  UnionStripedError err ->
    Striped.renderStripedError err
  UnionLogicalSchemaError err ->
    Logical.renderLogicalSchemaError err
  UnionLogicalMergeError err ->
    Logical.renderLogicalMergeError err
  UnionSchemaError err ->
    Schema.renderSchemaUnionError err

------------------------------------------------------------------------
-- General

unionSchemas :: Cons Boxed.Vector Schema.Table -> Either UnionTableError Schema.Table
unionSchemas =
  first UnionSchemaError . Cons.fold1M' Schema.union
{-# INLINABLE unionSchemas #-}

peekHead :: Monad m => Stream (Of x) m r -> EitherT UnionTableError m (x, Stream (Of x) m r)
peekHead input = do
  e <- lift $ Stream.next input
  case e of
    Left _r ->
      left UnionEmptyInput
    Right (hd, tl) ->
      pure (hd, Stream.cons hd tl)
{-# INLINABLE peekHead #-}

hasData :: Input m -> Bool
hasData =
  not . Map.null . inputData
{-# INLINABLE hasData #-}

replaceData :: Map Logical.Value Logical.Value -> Input m -> Input m
replaceData values input =
  input {
      inputData = values
    }
{-# INLINABLE replaceData #-}

replaceStream :: Stream (Of Logical.Table) m () ->  Input m -> Input m
replaceStream stream input =
  input {
      inputStream = Just stream
    }
{-# INLINABLE replaceStream #-}

isClosed :: Input m -> Bool
isClosed =
  isNothing . inputStream
{-# INLINABLE isClosed #-}

closeStream :: Input m -> Input m
closeStream input =
  input {
      inputStream = Nothing
    }
{-# INLINABLE closeStream #-}

updateInput :: Monad m => Input m -> EitherT UnionTableError m (Input m)
updateInput input =
  case inputStream input of
    Nothing ->
      pure input
    Just stream ->
      if hasData input then
        pure input
      else do
        e <- lift $ Stream.next stream
        case e of
          Left () ->
            pure $
              closeStream input

          Right (hd, tl) -> do
            values <- firstT UnionLogicalSchemaError . hoistEither $ Logical.takeMap hd
            pure . replaceStream tl $ replaceData values input
{-# INLINABLE updateInput #-}

unionStep :: Monad m => Cons Boxed.Vector (Input m) -> EitherT UnionTableError m (Step m)
unionStep inputs = do
  step <- firstT UnionLogicalMergeError . hoistEither . Logical.unionStep $ fmap inputData inputs
  pure $
    Step
      (Logical.unionComplete step)
      (Cons.zipWith replaceData (Logical.unionRemaining step) inputs)
{-# INLINABLE unionStep #-}

unionInput ::
     Monad m
  => Cons Boxed.Vector (Input m)
  -> Stream (Of Logical.Table) (EitherT UnionTableError m) ()
unionInput inputs0 = do
  inputs1 <- lift $ traverse updateInput inputs0
  if Cons.all isClosed inputs1 then do
    pure ()
  else do
    Step values inputs2 <- lift $ unionStep inputs1
    when (not $ Map.null values) .
      Stream.yield $ Logical.Map values
    unionInput inputs2
{-# INLINABLE unionInput #-}

unionLogical ::
     Monad m
  => Schema.Table
  -> Cons Boxed.Vector (Stream (Of Logical.Table) m ())
  -> Stream (Of Logical.Table) (EitherT UnionTableError m) ()
unionLogical schema inputs = do
  Stream.whenEmpty (Logical.empty schema) $
    unionInput $ fmap (Input Map.empty . Just) inputs
{-# INLINABLE unionLogical #-}

unionStripedWith ::
     Monad m
  => Schema.Table
  -> Cons Boxed.Vector (Stream (Of Striped.Table) m ())
  -> Stream (Of Striped.Table) (EitherT UnionTableError m) ()
unionStripedWith schema inputs0 = do
  let
    fromStriped =
      Stream.mapM (hoistEither . first UnionStripedError . Striped.toLogical) .
      Stream.mapM (hoistEither . first UnionStripedError . Striped.transmute schema) .
      hoist lift

  hoist squash .
    Stream.mapM (hoistEither . first UnionStripedError . Striped.fromLogical schema) $
    unionLogical schema (fmap fromStriped inputs0)
{-# INLINABLE unionStripedWith #-}

unionStriped ::
     Monad m
  => Cons Boxed.Vector (Stream (Of Striped.Table) m ())
  -> Stream (Of Striped.Table) (EitherT UnionTableError m) ()
unionStriped inputs0 = do
  (heads, inputs1) <- fmap Cons.unzip . lift $ traverse peekHead inputs0
  schema <- lift . hoistEither . unionSchemas $ fmap Striped.schema heads
  unionStripedWith schema inputs1
{-# INLINABLE unionStriped #-}
