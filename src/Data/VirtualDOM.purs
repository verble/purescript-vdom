module Data.VirtualDOM
  ( VNode
  , DOM
  , EventListener(..)
  , h
  , text
  , prop
  , with
  , patch
  ) where

import Prelude
import Data.StrMap as Map
import Control.Monad.Eff (Eff)
import Data.Array ((!!), (..), length)
import Data.Foldable (sequence_)
import Data.Maybe (maybe, Maybe(Just, Nothing))
import Data.StrMap (StrMap)
import Data.Tuple (Tuple)



type Props = StrMap String

data EventListener e l v = On String (v → Eff e Unit)

-- | The type of virtual DOM nodes. Use either `h` or `text` to create
-- | them.
data VNode e l v
  = Element
    { name :: String
    , props :: Props
    , listeners :: Array (EventListener e l v)
    , children :: Array (VNode e l v)
    }
  | Text String

instance showVNode :: Show (VNode e l v) where
  show (Element n) = "<VNode:" <> n.name <> ">"
  show (Text t) = "\"" <> t <> "\""

-- | Create a virtual DOM element, using a Hyperscript like interface.
h :: ∀ e l v. String → Props → Array (VNode e l v) → VNode e l v
h name props children = Element {name, props, children, listeners: []}

-- | Create a virtual DOM text node.
text :: ∀ e l v. String → VNode e l v
text t = Text t

-- | A shorthand for making `Props`: turns a list of tuples into a `Props`
-- | value.
-- |
-- | Example:
-- |
-- |     prop [ "class" /\ "caturday"
-- |          , "href" /\ "http://caturday.tumblr.com/"
-- |          ]
prop :: Array (Tuple String String) → Props
prop = Map.fromFoldable

-- | Attach event listeners to a virtual DOM element.
-- |
-- | These will be installed on the actual DOM element the first time
-- | it's created, and only then.
with :: ∀ e l v. VNode e l v → Array (EventListener e l v) → VNode e l v
with (Element n) listeners = Element $ n {listeners = listeners}
with n _ = n



-- | An API interface for DOM operations. The `Data.VirtualDOM.DOM` module
-- | provides an implementation for the regular DOM. You could provide
-- | your own, for things like server side rendering.
type DOM e l v =
  { createElement :: String → Eff e l
  , createElementNS :: String → String → Eff e l
  , createTextNode :: String → Eff e l
  , replaceChild :: l → l → l → Eff e Unit
  , removeChild :: l → l → Eff e Unit
  , appendChild :: l → l → Eff e Unit
  , childCount :: l → Eff e Int
  , childAt :: Int → l → Eff e (Maybe l)
  , setTextContent :: String → l → Eff e Unit
  , setAttribute :: String → String → l → Eff e Unit
  , removeAttribute :: String → l → Eff e Unit
  , addEventListener :: String → (v → Eff e Unit) → l → Eff e Unit
  }



createElement :: ∀ e l v. DOM e l v → VNode e l v → Eff e l
createElement api (Element e) = do
  el ← api.createElement e.name
  Map.foldM (\_ k v → api.setAttribute k v el) unit e.props
  sequence_ $ e.listeners <#> addListener api el
  sequence_ $ e.children <#> (createElement api >=> flip api.appendChild el)
  pure el
createElement api (Text t) = api.createTextNode t

addListener :: ∀ e l v. DOM e l v → l → EventListener e l v → Eff e Unit
addListener api target (On name handler) = api.addEventListener name handler target

changed :: ∀ e l v. VNode e l v → VNode e l v → Boolean
changed (Element e1) (Element e2) = e1.name /= e2.name
changed (Text t1) (Text t2) = t1 /= t2
changed _ _ = true

updateProps :: ∀ e l v. DOM e l v → l → Props → Props → Eff e Unit
updateProps api target old new =
  sequence_ (update <$> Map.keys (Map.union old new))
  where
    update key =
      case Map.lookup key old, Map.lookup key new of
        Nothing, Just value → api.setAttribute key value target
        Just _, Nothing → api.removeAttribute key target
        Just prev, Just next → when (prev /= next) $ api.setAttribute key next target
        Nothing, Nothing → pure unit



-- | Given a `DOM` interface, a target node, and two virtual DOM nodes,
-- | update the contents of the target node to reflect the differences
-- | between the virtual DOM nodes.
-- |
-- | To use this, call it the first time with `Nothing` as the old node.
-- | This will do nothing but create the new node. Then, each subsequent
-- | update, call it with the previous new node as the old node.
-- |
-- | An example, using `Signal`, and assuming a `Signal (VNode e l v)`
-- | as input, and `api` from `Data.VirtualDOM.DOM`:
-- |
-- |     render :: ∀ e. Node → Signal (VNode e Node Event) → Eff (dom :: DOM | e) Unit
-- |     render target input =
-- |       runSignal $ withPrevious ~> patchDOM
-- |       where
-- |         withPrevious = foldp go (Tuple Nothing Nothing) input
-- |         go next (Tuple _ prev) = Tuple prev next
-- |         patchDOM (Tuple prev next) = patch api target prev next
patch :: ∀ e l v. DOM e l v → l → Maybe (VNode e l v) → Maybe (VNode e l v) → Eff e Unit
patch api target old new = run target old new 0
  where
    run :: l → Maybe (VNode e l v) → Maybe (VNode e l v) → Int → Eff e Unit

    run _ Nothing Nothing _ = pure unit

    run parent Nothing (Just new) _ = do
      el ← createElement api new
      api.appendChild el parent

    run parent (Just _) Nothing index = do
      child ← api.childAt index parent
      case child of
        Just n → api.removeChild n parent
        Nothing → pure unit

    run parent (Just (Text old)) (Just (Text new)) index =
      when (old /= new) do
        me ← api.childAt index parent
        maybe (pure unit) (\t → api.setTextContent new t) me

    run parent (Just old) (Just new) index = do
      me' ← api.childAt index parent
      case me' of
        Nothing → pure unit
        Just me →
          if (changed old new) then do
            n ← createElement api new
            api.replaceChild n me parent
          else do
            case old, new of
              Element {props: oldProps}, Element {props: newProps} →
                updateProps api me oldProps newProps
              _, _ → pure unit
            walk me old new

    walk :: l → VNode e l v → VNode e l v → Eff e Unit
    walk target (Element old) (Element new) = do
      let r = 0 .. ((max (length old.children) (length new.children)) - 1)
      sequence_ $ map (\i → run target (old.children !! i) (new.children !! i) i) r
    walk _ _ _ = pure unit



-- -- TODO: these could be more efficient.
-- hookPre :: ∀ a e. Array (Hook e a) → Eff e Unit
-- hookPre = filterMap run >>> sequence_
--   where run (Pre eff) = Just eff
--         run _ = Nothing

-- hookInit :: ∀ a e. VNode e a → Array (Hook e a) → Eff e Unit
-- hookInit node = filterMap run >>> sequence_
--   where run (Init f) = Just (f node)
--         run _ = Nothing

-- hookCreate :: ∀ a e. VNode e a → VNode e a → Array (Hook e a) → Eff e Unit
-- hookCreate n1 n2 = filterMap run >>> sequence_
--   where run (Create f) = Just (f n1 n2)
--         run _ = Nothing

-- hookInsert :: ∀ a e. VNode e a → Array (Hook e a) → Eff e Unit
-- hookInsert node = filterMap run >>> sequence_
--   where run (Insert f) = Just (f node)
--         run _ = Nothing

-- hookPrepatch :: ∀ a e. VNode e a → VNode e a → Array (Hook e a) → Eff e Unit
-- hookPrepatch n1 n2 = filterMap run >>> sequence_
--   where run (Prepatch f) = Just (f n1 n2)
--         run _ = Nothing

-- hookUpdate :: ∀ a e. VNode e a → VNode e a → Array (Hook e a) → Eff e Unit
-- hookUpdate n1 n2 = filterMap run >>> sequence_
--   where run (Update f) = Just (f n1 n2)
--         run _ = Nothing

-- hookPostpatch :: ∀ a e. VNode e a → VNode e a → Array (Hook e a) → Eff e Unit
-- hookPostpatch n1 n2 = filterMap run >>> sequence_
--   where run (Postpatch f) = Just (f n1 n2)
--         run _ = Nothing

-- hookDestroy :: ∀ a e. VNode e a → Array (Hook e a) → Eff e Unit
-- hookDestroy node = filterMap run >>> sequence_
--   where run (Destroy f) = Just (f node)
--         run _ = Nothing

-- hookRemove :: ∀ a e. VNode e a → Eff e Unit → Array (Hook e a) → Eff e Unit
-- hookRemove node eff = filterMap run >>> sequence_
--   where run (Remove f) = Just (f node eff)
--         run _ = Nothing

-- hookPost :: ∀ a e. Array (Hook e a) → Eff e Unit
-- hookPost = filterMap run >>> sequence_
--   where run (Post eff) = Just eff
--         run _ = Nothing
