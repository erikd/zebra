{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# OPTIONS_GHC -funbox-strict-fields #-}
module Zebra.Table.Data (
    Field(..)
  , FieldName(..)
  , Variant(..)
  , VariantName(..)
  , Tag(..)
  , Default(..)

  , hasVariant
  , lookupVariant
  , forVariant

  , xmapM
  , ximapM
  , cmapM
  , cimapM

  , foreignOfTags
  , tagsOfForeign
  ) where

import           Data.String (IsString(..))
import qualified Data.Text as Text
import qualified Data.Vector.Mutable as MBoxed

import           Foreign.Storable (Storable)

import           GHC.Generics (Generic)

import           P

import           System.IO.Unsafe (unsafePerformIO)

import qualified X.Data.Vector as Boxed
import           X.Data.Vector.Cons (Cons)
import qualified X.Data.Vector.Cons as Cons
import qualified X.Data.Vector.Storable as Storable
import           X.Text.Show (gshowsPrec)


newtype FieldName =
  FieldName {
      unFieldName :: Text
    } deriving (Eq, Ord, Generic)

instance NFData FieldName

instance Show FieldName where
  showsPrec p =
    showsPrec p . unFieldName

instance IsString FieldName where
  fromString =
    FieldName . Text.pack

data Field a =
  Field {
      fieldName :: !FieldName
    , fieldData :: !a
    } deriving (Eq, Ord, Generic, Functor, Foldable, Traversable)

instance NFData a => NFData (Field a)

instance Show a => Show (Field a) where
  showsPrec =
    gshowsPrec

newtype VariantName =
  VariantName {
      unVariantName :: Text
    } deriving (Eq, Ord, Generic)

instance NFData VariantName

instance Show VariantName where
  showsPrec p =
    showsPrec p . unVariantName

instance IsString VariantName where
  fromString =
    VariantName . Text.pack

data Variant a =
  Variant {
      variantName :: !VariantName
    , variantData :: !a
    } deriving (Eq, Ord, Generic, Functor, Foldable, Traversable)

instance NFData a => NFData (Variant a)

instance Show a => Show (Variant a) where
  showsPrec =
    gshowsPrec

newtype Tag =
  Tag {
      unTag :: Int64
    } deriving (Eq, Ord, Generic, Storable, Num, Enum, Real, Integral)

instance NFData Tag

instance Show Tag where
  showsPrec =
    gshowsPrec

--
-- Ideally this would contain a Zebra.Table.Logical.Table/Value which is the
-- default value for the Table/Column. However, all we need right now is to
-- be able to default to empty lists/maps and 'none' enum values, so we go
-- for a simpler approach where the default value is implied.
--
data Default =
    DenyDefault  -- ^ Table/column can NOT be replaced by a default value if missing.
  | AllowDefault -- ^ Table/column can be replaced by a default value if missing.
    deriving (Eq, Ord, Show, Generic)

instance NFData Default

------------------------------------------------------------------------

hasVariant :: Tag -> Cons Boxed.Vector (Variant a) -> Bool
hasVariant tag xs =
  fromIntegral tag < Cons.length xs
{-# INLINE hasVariant #-}

lookupVariant :: Tag -> Cons Boxed.Vector (Variant a) -> Maybe (Variant a)
lookupVariant tag xs =
  Cons.index (fromIntegral tag) xs
{-# INLINE lookupVariant #-}

forVariant ::
     Cons Boxed.Vector (Variant a)
  -> (Tag -> VariantName -> a -> Either x b)
  -> Either x (Cons Boxed.Vector (Variant b))
forVariant xs f =
  flip cimapM xs $ \i (Variant name x) ->
    Variant name <$> f (fromIntegral i) name x
{-# INLINE forVariant #-}

xmapM :: (a -> Either x b) -> Boxed.Vector a -> Either x (Boxed.Vector b)
xmapM f xs = {-# SCC xmapM #-}
  ximapM (\_ x -> f x) xs
{-# INLINE xmapM #-}

ximapM :: (Int -> a -> Either x b) -> Boxed.Vector a -> Either x (Boxed.Vector b)
ximapM f xs = {-# SCC ximapM #-}
  unsafePerformIO $ do
    let
      !n =
        Boxed.length xs

    m <- MBoxed.new n

    let
      loop !i =
        if i < n then
          let
            !x0 =
              Boxed.unsafeIndex xs i
          in
            case f i x0 of
              Left err ->
                pure $! Left err
              Right x -> do
                MBoxed.unsafeWrite m i x
                loop (i + 1)
        else do
          !ys <- Boxed.unsafeFreeze m
          pure $! Right ys

    loop 0
{-# INLINE ximapM #-}

cmapM :: (a -> Either x b) -> Cons Boxed.Vector a -> Either x (Cons Boxed.Vector b)
cmapM f = {-# SCC cmapM #-}
  fmap Cons.unsafeFromVector .
  xmapM f .
  Cons.toVector
{-# INLINE cmapM #-}

cimapM :: (Int -> a -> Either x b) -> Cons Boxed.Vector a -> Either x (Cons Boxed.Vector b)
cimapM f = {-# SCC cimapM #-}
  fmap Cons.unsafeFromVector .
  ximapM f .
  Cons.toVector
{-# INLINE cimapM #-}

------------------------------------------------------------------------

foreignOfTags :: Storable.Vector Tag -> Storable.Vector Int64
foreignOfTags =
  Storable.unsafeCast
{-# INLINE foreignOfTags #-}

tagsOfForeign :: Storable.Vector Int64 -> Storable.Vector Tag
tagsOfForeign =
  Storable.unsafeCast
{-# INLINE tagsOfForeign #-}
