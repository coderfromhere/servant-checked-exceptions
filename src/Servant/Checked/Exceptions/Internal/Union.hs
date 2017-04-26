{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

{- |
Module      :  Servant.Checked.Exceptions.Internal.Union

Copyright   :  Dennis Gosnell 2017
License     :  BSD3

Maintainer  :  Dennis Gosnell (cdep.illabout@gmail.com)
Stability   :  experimental
Portability :  unknown

This module defines extensible sum-types.  This is similar to how
<https://hackage.haskell.org/package/vinyl vinyl> defines extensible records.

This is used extensively in the definition of the 'Evenlope' type in
"Servant.Checked.Exceptions.Internal.Envelope".

A large portion of the code from this module was taken from the
<https://hackage.haskell.org/package/union union> package.
-}

module Servant.Checked.Exceptions.Internal.Union
  (
  -- * Union
    Union(..)
  , union
  , absurdUnion
  , umap
  -- ** Optics
  , _This
  , _That
  -- ** Typeclasses
  , RIndex
  , UElem(..)
  , IsMember
  -- * OpenUnion
  , OpenUnion
  , openUnion
  , fromOpenUnion
  , fromOpenUnionOr
  , openUnionPrism
  , openUnionLift
  , openUnionMatch
  -- * Setup code for doctests
  -- $setup
  ) where

-- Imports for Union stuff
import Control.Applicative ((<|>))
import Control.Lens (Prism, Prism', iso, preview, prism, prism', review)
import Control.DeepSeq (NFData(rnf))
import Data.Aeson
       (FromJSON(parseJSON), ToJSON(toJSON), Value)
import Data.Aeson.Types (Parser)
import Data.Functor.Identity (Identity(Identity, runIdentity))
import Data.Typeable (Typeable)
import GHC.TypeLits (Nat, type (+))
import Text.Read (Read(readPrec), ReadPrec, (<++))

-- $setup
-- >>> :set -XDataKinds
-- >>> :set -XTypeOperators
-- >>> import Data.Text (Text)
-- >>> import Text.Read (readMaybe)

---------------------------------------
-- This is from Data.Vinyl.TypeLevel --
---------------------------------------

-- | A partial relation that gives the index of a value in a list.
--
-- Find the first item:
--
-- >>> import Data.Type.Equality ((:~:)(Refl))
-- >>> Refl :: RIndex String '[String, Int] :~: 0
-- Refl
--
-- Find the third item:
--
-- >>> Refl :: RIndex Char '[String, Int, Char] :~: 2
-- Refl
type family RIndex (r :: k) (rs :: [k]) :: Nat where
  RIndex r (r ': rs) = 0
  RIndex r (s ': rs) = 1 + (RIndex r rs)

-----------------------------
-- This is from Data.Union --
-----------------------------

-- | A 'Union' is parameterized by a universe @u@, an interpretation @f@
-- and a list of labels @as@. The labels of the union are given by
-- inhabitants of the kind @u@; the type of values at any label @a ::
-- u@ is given by its interpretation @f a :: *@.
data Union (f :: u -> *) (as :: [u]) where
  This :: !(f a) -> Union f (a ': as)
  That :: !(Union f as) -> Union f (a ': as)
  deriving (Typeable)

-- | Case analysis for 'Union'.
--
--  Here is an example of matching on a 'This':
--
-- >>> let u = This (Identity "hello") :: Union Identity '[String, Int]
-- >>> let runIdent = runIdentity :: Identity String -> String
-- >>> union (const "not a String") runIdent u
-- "hello"
--
-- Here is an example of matching on a 'That':
--
-- >>> let v = That (This (Identity 3.3)) :: Union Identity '[String, Double, Int]
-- >>> union (const "not a String") runIdent v
-- "not a String"
union :: (Union f as -> c) -> (f a -> c) -> Union f (a ': as) -> c
union _ onThis (This a) = onThis a
union onThat _ (That u) = onThat u

-- | Since a union with an empty list of labels is uninhabited, we
-- can recover any type from it.
absurdUnion :: Union f '[] -> a
absurdUnion u = case u of {}

-- | Map over the interpretation @f@ in the 'Union'.
--
-- Here is an example of changing a @'Union' 'Identity' \'['String', 'Int']@ to
-- @'Union' 'Maybe' \'['String', 'Int']@:
--
-- >>> let u = This (Identity "hello") :: Union Identity '[String, Int]
-- >>> umap (Just . runIdentity) u :: Union Maybe '[String, Int]
-- Just "hello"
umap :: (forall a . f a -> g a) -> Union f as -> Union g as
umap f (This a) = This $ f a
umap f (That u) = That $ umap f u

-- | Lens-compatible 'Prism' for 'This'.
--
-- Use '_This' to construct a 'Union':
--
-- >>> review _This (Just "hello") :: Union Maybe '[String]
-- Just "hello"
--
-- Use '_This' to try to destruct a 'Union' into a @f a@:
--
-- >>> let u = This (Identity "hello") :: Union Identity '[String, Int]
-- >>> preview _This u :: Maybe (Identity String)
-- Just (Identity "hello")
--
-- Use '_This' to try to destruct a 'Union' into a @f a@ (unsuccessfully):
--
-- >>> let v = That (This (Identity 3.3)) :: Union Identity '[String, Double, Int]
-- >>> preview _This v :: Maybe (Identity String)
-- Nothing
_This :: Prism (Union f (a ': as)) (Union f (b ': as)) (f a) (f b)
_This = prism This (union (Left . That) Right)
{-# INLINE _This #-}

-- | Lens-compatible 'Prism' for 'That'.
--
-- Use '_That' to construct a 'Union':
--
-- >>> let u = This (Just "hello") :: Union Maybe '[String]
-- >>> review _That u :: Union Maybe '[Double, String]
-- Just "hello"
--
-- Use '_That' to try to peel off a 'That' from a 'Union':
--
-- >>> let v = That (This (Identity "hello")) :: Union Identity '[Int, String]
-- >>> preview _That v :: Maybe (Union Identity '[String])
-- Just (Identity "hello")
--
-- Use '_That' to try to peel off a 'That' from a 'Union' (unsuccessfully):
--
-- >>> let w = This (Identity 3.5) :: Union Identity '[Double, String]
-- >>> preview _That w :: Maybe (Union Identity '[String])
-- Nothing
_That :: Prism (Union f (a ': as)) (Union f (a ': bs)) (Union f as) (Union f bs)
_That = prism That (union Right (Left . This))
{-# INLINE _That #-}

-- | @'UElem' a as i@ provides a way to potentially get an @f a@ out of a
-- @'Union' f as@ ('unionMatch').  It also provides a way to create a
-- @'Union' f as@ from an @f a@ ('unionLift').
--
-- This is safe because of the 'RIndex' contraint. This 'RIndex' constraint
-- tells us that there /actually is/ an @a@ in @as@ at index @i@.
--
-- As an end-user, you should never need to implement an additional instance of
-- this typeclass.
class i ~ RIndex a as => UElem (a :: u) (as :: [u]) (i :: Nat) where
  {-# MINIMAL unionPrism | unionLift, unionMatch #-}

  -- | This is implemented as @'prism'' 'unionLift' 'unionMatch'@.
  unionPrism :: Prism' (Union f as) (f a)
  unionPrism = prism' unionLift unionMatch

  -- | This is implemented as @'review' 'unionPrism'@.
  unionLift :: f a -> Union f as
  unionLift = review unionPrism

  -- | This is implemented as @'preview' 'unionPrism'@.
  unionMatch :: Union f as -> Maybe (f a)
  unionMatch = preview unionPrism

instance UElem a (a ': as) 0 where
  unionPrism :: Prism' (Union f (a ': as)) (f a)
  unionPrism = _This
  {-# INLINE unionPrism #-}

instance {-# OVERLAPPABLE #-} (RIndex a (b ': as) ~ n, UElem a as i, n ~ (1 + i))
    => UElem a (b ': as) n where
  unionPrism :: Prism' (Union f (b ': as)) (f a)
  unionPrism = _That . unionPrism
  {-# INLINE unionPrism #-}

-- | This is a helpful 'Constraint' synonym to assert that @a@ is a member of
-- @as@.
type IsMember (a :: u) (as :: [u]) = UElem a as (RIndex a as)

-- | We can use @'Union' 'Identity'@ as a standard open sum type.
type OpenUnion = Union Identity

-- | Case analysis for 'OpenUnion'.
--
--  Here is an example of successfully matching:
--
-- >>> let string = "hello" :: String
-- >>> let o = openUnionLift string :: OpenUnion '[String, Int]
-- >>> openUnion (const "not a String") id o
-- "hello"
--
-- Here is an example of unsuccessfully matching:
--
-- >>> let double = 3.3 :: Double
-- >>> let p = openUnionLift double :: OpenUnion '[String, Double, Int]
-- >>> openUnion (const "not a String") id p
-- "not a String"
openUnion
  :: (OpenUnion as -> c) -> (a -> c) -> OpenUnion (a ': as) -> c
openUnion onThat onThis = union onThat (onThis . runIdentity)

-- | This is similar to 'fromMaybe' for an 'OpenUnion'.
--
--  Here is an example of successfully matching:
--
-- >>> let string = "hello" :: String
-- >>> let o = openUnionLift string :: OpenUnion '[String, Int]
-- >>> fromOpenUnion (const "not a String") o
-- "hello"
--
-- Here is an example of unsuccessfully matching:
--
-- >>> let double = 3.3 :: Double
-- >>> let p = openUnionLift double :: OpenUnion '[String, Double, Int]
-- >>> fromOpenUnion (const "not a String") p
-- "not a String"
fromOpenUnion
  :: (OpenUnion as -> a) -> OpenUnion (a ': as) -> a
fromOpenUnion onThat = openUnion onThat id

-- | Flipped version of 'fromOpenUnion'.
fromOpenUnionOr
  :: OpenUnion (a ': as) -> (OpenUnion as -> a) -> a
fromOpenUnionOr = flip fromOpenUnion

-- | Just like 'unionPrism' but for 'OpenUnion'.
openUnionPrism
  :: forall a as.
     IsMember a as
  => Prism' (OpenUnion as) a
openUnionPrism = unionPrism . iso runIdentity Identity
{-# INLINE openUnionPrism #-}

-- | Just like 'unionLift' but for 'OpenUnion'.
--
-- Creating an 'OpenUnion':
--
-- >>> let string = "hello" :: String
-- >>> openUnionLift string :: OpenUnion '[Double, String, Int]
-- Identity "hello"
openUnionLift
  :: forall a as.
     IsMember a as
  => a -> OpenUnion as
openUnionLift = review openUnionPrism

-- | Just like 'unionMatch' but for 'OpenUnion'.
--
-- Successful matching:
--
-- >>> let string = "hello" :: String
-- >>> let o = openUnionLift string :: OpenUnion '[Double, String, Int]
-- >>> openUnionMatch o :: Maybe String
-- Just "hello"
--
-- Failure matching:
--
-- >>> let double = 3.3 :: Double
-- >>> let p = openUnionLift double :: OpenUnion '[Double, String]
-- >>> openUnionMatch p :: Maybe String
-- Nothing
openUnionMatch
  :: forall a as.
     IsMember a as
  => OpenUnion as -> Maybe a
openUnionMatch = preview openUnionPrism

instance NFData (Union f '[]) where
  rnf = absurdUnion

instance (NFData (f a), NFData (Union f as)) => NFData (Union f (a ': as)) where
  rnf = union rnf rnf

instance Show (Union f '[]) where
  showsPrec _ = absurdUnion

instance (Show (f a), Show (Union f as)) => Show (Union f (a ': as)) where
  showsPrec n = union (showsPrec n) (showsPrec n)

-- | This will always fail, since @'Union' f \'[]@ is effectively 'Void'.
instance Read (Union f '[]) where
  readsPrec :: Int -> ReadS (Union f '[])
  readsPrec _ _ = []

-- | This is only a valid instance when the 'Read' instances for the types
-- don't overlap.
--
-- For instance, imagine we are working with a 'Union' of a 'String' and a 'Double'.
-- @3.5@ can only be read as a 'Double', not as a 'String'.
-- Oppositely, @\"hello\"@ can only be read as a 'String', not as a 'Double'.
--
-- >>> let o = readMaybe "Identity 3.5" :: Maybe (Union Identity '[Double, String])
-- >>> o
-- Just (Identity 3.5)
-- >>> o >>= openUnionMatch :: Maybe Double
-- Just 3.5
-- >>> o >>= openUnionMatch :: Maybe String
-- Nothing
--
-- >>> let p = readMaybe "Identity \"hello\"" :: Maybe (Union Identity '[Double, String])
-- >>> p
-- Just (Identity "hello")
-- >>> p >>= openUnionMatch :: Maybe Double
-- Nothing
-- >>> p >>= openUnionMatch :: Maybe String
-- Just "hello"
--
-- However, imagine are we working with a 'Union' of a 'String' and 'Text'.
-- @\"hello\"@ can be 'read' as both a 'String' and 'Text'.  However, in the
-- following example, it can only be read as a 'String':
--
-- >>> let q = readMaybe "Identity \"hello\"" :: Maybe (Union Identity '[String, Text])
-- >>> q
-- Just (Identity "hello")
-- >>> q >>= openUnionMatch :: Maybe String
-- Just "hello"
-- >>> q >>= openUnionMatch :: Maybe Text
-- Nothing
--
-- If the order of the types is flipped around, we are are able to read @\"hello\"@
-- as a 'Text' but not as a 'String'.
--
-- >>> let r = readMaybe "Identity \"hello\"" :: Maybe (Union Identity '[Text, String])
-- >>> r
-- Just (Identity "hello")
-- >>> r >>= openUnionMatch :: Maybe String
-- Nothing
-- >>> r >>= openUnionMatch :: Maybe Text
-- Just "hello"
instance (Read (f a), Read (Union f as)) => Read (Union f (a ': as)) where
  readPrec :: ReadPrec (Union f (a ': as))
  readPrec = fmap This readPrec <++ fmap That readPrec

instance Eq (Union f '[]) where
  (==) = absurdUnion

instance (Eq (f a), Eq (Union f as)) => Eq (Union f (a ': as)) where
    This a1 == This a2 = a1 == a2
    That u1 == That u2 = u1 == u2
    _       == _       = False

instance Ord (Union f '[]) where
  compare = absurdUnion

instance (Ord (f a), Ord (Union f as)) => Ord (Union f (a ': as))
  where
    compare (This a1) (This a2) = compare a1 a2
    compare (That u1) (That u2) = compare u1 u2
    compare (This _)  (That _)  = LT
    compare (That _)  (This _)  = GT

instance ToJSON (Union f '[]) where
  toJSON :: Union f '[] -> Value
  toJSON = absurdUnion

instance (ToJSON (f a), ToJSON (Union f as)) => ToJSON (Union f (a ': as)) where
  toJSON :: Union f (a ': as) -> Value
  toJSON = union toJSON toJSON

-- | This will always fail, since @'Union' f \'[]@ is effectively 'Void'.
instance FromJSON (Union f '[]) where
  parseJSON :: Value -> Parser (Union f '[])
  parseJSON _ = fail "Value of Union f '[] can never be created"

-- | This is only a valid instance when the 'FromJSON' instances for the types
-- don't overlap.
--
-- This is similar to the 'Read' instance.
instance (FromJSON (f a), FromJSON (Union f as)) => FromJSON (Union f (a ': as)) where
  parseJSON :: Value -> Parser (Union f (a ': as))
  parseJSON val = fmap This (parseJSON val) <|> fmap That (parseJSON val)

-- instance f ~ Identity => Exception (Union f '[])

-- instance
--     ( f ~ Identity
--     , Exception a
--     , Typeable as
--     , Exception (Union f as)
--     ) => Exception (Union f (a ': as))
--   where
--     toException = union toException (toException . runIdentity)
--     fromException sE = matchR <|> matchL
--       where
--         matchR = This . Identity <$> fromException sE
--         matchL = That <$> fromException sE
