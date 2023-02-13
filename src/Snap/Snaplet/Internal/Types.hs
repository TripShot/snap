{-# LANGUAGE BangPatterns               #-}
{-# LANGUAGE CPP                        #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ImpredicativeTypes         #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}

#ifndef MIN_VERSION_comonad
#define MIN_VERSION_comonad(x,y,z) 1
#endif

module Snap.Snaplet.Internal.Types where

------------------------------------------------------------------------------
import           Control.Applicative          (Alternative)
import           Control.Lens                 (ALens', makeLenses, set)
import           Control.Monad                (MonadPlus, liftM)
import           Control.Monad.Base           (MonadBase (..))
import           Control.Monad.Fail           (MonadFail)
import           Control.Monad.Reader         (MonadIO (..), MonadReader (ask, local))
import           Control.Monad.State.Class    (MonadState (get, put), gets)
import           Control.Monad.Trans.Control  (MonadBaseControl (..))
import           Control.Monad.Trans.Writer   (WriterT)
import           Data.ByteString              (ByteString)
import qualified Data.ByteString.Char8        as B (dropWhile, intercalate, null, reverse)
import           Data.Configurator.Types      (Config)
import           Data.IORef                   (IORef)
import           Data.Text                    (Text)
import           Snap.Core                    (MonadSnap, Request (rqClientAddr), Snap, bracketSnap, getRequest, pass, writeText)
import qualified Snap.Snaplet.Internal.Lensed as L (Lensed (..), runLensed, with, withTop)
import qualified Snap.Snaplet.Internal.LensT  as LT (LensT, getBase, with, withTop)

#if !MIN_VERSION_base(4,8,0)
import           Control.Applicative          (Applicative)
import           Data.Monoid                  (Monoid (mappend, mempty))
#endif

#if !MIN_VERSION_base(4,11,0)
import           Data.Semigroup               (Semigroup(..))
#endif

------------------------------------------------------------------------------


------------------------------------------------------------------------------
-- | An opaque data type holding internal snaplet configuration data.  It is
-- exported publicly because the getOpaqueConfig function in MonadSnaplet
-- makes implementing new instances of MonadSnaplet more convenient.
data SnapletConfig = SnapletConfig
    { _scAncestry        :: [Text]
    , _scFilePath        :: FilePath
    , _scId              :: Maybe Text
    , _scDescription     :: Text
    , _scUserConfig      :: Config
    , _scRouteContext    :: [ByteString]
    , _scRoutePattern    :: Maybe ByteString
        -- ^ Holds the actual route pattern passed to addRoutes for the
        -- current handler.  Nothing during initialization and before route
        -- dispatech.
    , _reloader          :: IO (Either Text Text) -- might change
        -- ^ This is the universal reload action for the top-level site.  We
        -- can't update this in place to be a reloader for each individual
        -- snaplet because individual snaplets can't be reloaded in isolation
        -- without losing effects that subsequent hooks may have had.
    }

makeLenses ''SnapletConfig


------------------------------------------------------------------------------
-- | Joins a reversed list of directories into a path.
buildPath :: [ByteString] -> ByteString
buildPath ps = B.intercalate "/" $ filter (not . B.null) $ reverse ps


------------------------------------------------------------------------------
-- | Joins a reversed list of directories into a path.
getRootURL :: SnapletConfig -> ByteString
getRootURL sc = buildPath $ _scRouteContext sc


------------------------------------------------------------------------------
-- | Snaplet's type parameter 's' here is user-defined and can be any Haskell
-- type.  A value of type @Snaplet s@ countains a couple of things:
--
-- * a value of type @s@, called the \"user state\".
--
-- * some bookkeeping data the framework uses to plug things together, like
--   the snaplet's configuration, the snaplet's root directory on the
--   filesystem, the snaplet's root URL, and so on.
data Snaplet s = Snaplet
    { _snapletConfig   :: SnapletConfig
    , _snapletModifier :: s -> IO ()
        -- ^ See the _reloader comment for why we have to use this to reload
        -- single snaplets in isolation.  This action won't actually run the
        -- initializer at all.  It will only modify the existing state.  It is
        -- the responsibility of the snaplet author to avoid using this in
        -- situations where it will destroy data in its state that was created
        -- by subsequent hook actions.
    , _snapletValue    :: s
    }

makeLenses ''Snaplet

--instance Functor Snaplet where
--  fmap f (Snaplet c r a) = Snaplet c r (f a)
--
--instance Foldable Snaplet where
--  foldMap f (Snaplet _ _ a) = f a
--
--instance Traversable Snaplet where
--  traverse f (Snaplet c r a) = Snaplet c r <$> f a
--
--instance Comonad Snaplet where
--  extract (Snaplet _ _ a) = a
--
-- #if !(MIN_VERSION_comonad(3,0,0))
-- instance Extend Snaplet where
-- #endif
--   extend f w@(Snaplet c r _) = Snaplet c r (f w)

{-
------------------------------------------------------------------------------
-- | A lens referencing the opaque SnapletConfig data type held inside
-- Snaplet.
snapletConfig :: SimpleLens (Snaplet a) SnapletConfig


------------------------------------------------------------------------------
-- | A lens referencing the user-defined state type wrapped by a Snaplet.
snapletValue :: SimpleLens (Snaplet a) a
-}


-- NOTE: We cannot use one of the smaller lens packages because none of them
-- include ALens'.  We have to use ALens' because we use lenses inside f's...
-- f (Lens a b).  That requires ImpredicativeTypes which doesn't work.  We
-- also can't inline the type aliases because ALens' uses Pretext which is a
-- newtype and can't be supplied outside lens in a compatible way.

------------------------------------------------------------------------------
type SnapletLens s a = ALens' s (Snaplet a)


------------------------------------------------------------------------------
-- | Transforms a lens of the type you get from makeLenses to an similar lens
-- that is more suitable for internal use.
subSnaplet :: SnapletLens a b
           -> SnapletLens (Snaplet a) b
subSnaplet l = snapletValue . l


------------------------------------------------------------------------------
-- | The m type parameter used in the MonadSnaplet type signatures will
-- usually be either Initializer or Handler, but other monads may sometimes be
-- useful.
--
-- Minimal complete definition:
--
-- * 'withTop'', 'with'', 'getLens', and 'getOpaqueConfig'.
--
class MonadSnaplet m where
    -- | Runs a child snaplet action in the current snaplet's context.  If you
    -- think about snaplet lenses using a filesystem path metaphor, the lens
    -- supplied to this snaplet must be a relative path.  In other words, the
    -- lens's base state must be the same as the current snaplet.
    with :: SnapletLens v v'
             -- ^ A relative lens identifying a snaplet
         -> m b v' a
             -- ^ Action from the lense's snaplet
         -> m b v a
    with l = with' (subSnaplet l)

    -- | Like 'with' but doesn't impose the requirement that the action
    -- being run be a descendant of the current snaplet.  Using our filesystem
    -- metaphor again, the lens for this function must be an absolute
    -- path--it's base must be the same as the current base.
    withTop :: SnapletLens b v'
                -- ^ An \"absolute\" lens identifying a snaplet
            -> m b v' a
                -- ^ Action from the lense's snaplet
            -> m b v a
    withTop l = withTop' (subSnaplet l)

    -- | A variant of 'with' accepting a lens from snaplet to snaplet.  Unlike
    -- the lens used in the above 'with' function, this lens formulation has
    -- an identity, which makes it useful in certain circumstances.  The
    -- lenses generated by 'makeLenses' will not work with this function,
    -- however the lens returned by 'getLens' will.
    --
    -- @with = with' . subSnaplet@
    with' :: SnapletLens (Snaplet v) v'
          -> m b v' a -> m b v a

    -- Not providing a definition for this function in terms of withTop'
    -- allows us to avoid extra Monad type class constraints, making the type
    -- signature easier to read.
    -- with' l m = flip withTop m . (l .) =<< getLens

    -- | The absolute version of 'with''
    withTop' :: SnapletLens (Snaplet b) v'
             -> m b v' a -> m b v a

    -- | Gets the lens for the current snaplet.
    getLens :: m b v (SnapletLens (Snaplet b) v)

    -- | Gets the current snaplet's opaque config data type.  You'll only use
    -- this function when writing MonadSnaplet instances.
    getOpaqueConfig :: m b v SnapletConfig
    -- NOTE: We can't just use a MonadState (Snaplet v) instance for this
    -- because Initializer has SnapletConfig, but doesn't have a full Snaplet.


------------------------------------------------------------------------------
-- | Gets a list of the names of snaplets that are direct ancestors of the
-- current snaplet.
getSnapletAncestry :: (Monad (m b v), MonadSnaplet m) => m b v [Text]
getSnapletAncestry = return . _scAncestry =<< getOpaqueConfig


------------------------------------------------------------------------------
-- | Gets the snaplet's path on the filesystem.
getSnapletFilePath :: (Monad (m b v), MonadSnaplet m) => m b v FilePath
getSnapletFilePath = return . _scFilePath =<< getOpaqueConfig


------------------------------------------------------------------------------
-- | Gets the current snaple's name.
getSnapletName :: (Monad (m b v), MonadSnaplet m) => m b v (Maybe Text)
getSnapletName = return . _scId =<< getOpaqueConfig


------------------------------------------------------------------------------
-- | Gets a human readable description of the snaplet.
getSnapletDescription :: (Monad (m b v), MonadSnaplet m) => m b v Text
getSnapletDescription = return . _scDescription =<< getOpaqueConfig


------------------------------------------------------------------------------
-- | Gets the config data structure for the current snaplet.
getSnapletUserConfig :: (Monad (m b v), MonadSnaplet m) => m b v Config
getSnapletUserConfig = return . _scUserConfig =<< getOpaqueConfig


------------------------------------------------------------------------------
-- | Gets the base URL for the current snaplet.  Directories get added to
-- the current snaplet path by calls to 'nestSnaplet'.
getSnapletRootURL :: (Monad (m b v), MonadSnaplet m) => m b v ByteString
getSnapletRootURL = liftM getRootURL getOpaqueConfig


------------------------------------------------------------------------------
-- | Constructs a url relative to the current snaplet.
snapletURL :: (Monad (m b v), MonadSnaplet m)
           => ByteString -> m b v ByteString
snapletURL suffix = do
    cfg <- getOpaqueConfig
    return $ buildPath (cleanSuffix : _scRouteContext cfg)
  where
    dropSlash = B.dropWhile (=='/')
    cleanSuffix = B.reverse $ dropSlash $ B.reverse $ dropSlash suffix


------------------------------------------------------------------------------
-- | Snaplet infrastructure is available during runtime request processing
-- through the Handler monad.  There aren't very many standalone functions to
-- read about here, but this is deceptive.  The key is in the type class
-- instances.  Handler is an instance of 'MonadSnap', which means it is the
-- monad you will use to write all your application routes.  It also has a
-- 'MonadSnaplet' instance, which gives you all the functionality described
-- above.
newtype Handler b v a =
    Handler { _unHandler :: L.Lensed (Snaplet b) (Snaplet v) Snap a }
  deriving ( Monad
           , Functor
           , Applicative
           , MonadFail
           , MonadIO
           , MonadPlus
           , Alternative
           , MonadSnap)


------------------------------------------------------------------------------
instance MonadBase IO (Handler b v) where
    liftBase = liftIO


------------------------------------------------------------------------------
newtype StMHandler b v a = StMHandler {
      unStMHandler :: StM (L.Lensed (Snaplet b) (Snaplet v) Snap) a
    }


instance MonadBaseControl IO (Handler b v) where
    type StM (Handler b v) a = StMHandler b v a
    liftBaseWith f = Handler
                       $ liftBaseWith
                       $ \g' -> f
                       $ \m -> liftM StMHandler
                       $ g' $ _unHandler m
    restoreM = Handler . restoreM . unStMHandler


------------------------------------------------------------------------------
-- | Gets the @Snaplet v@ from the current snaplet's state.
getSnapletState :: Handler b v (Snaplet v)
getSnapletState = Handler get


------------------------------------------------------------------------------
-- | Puts a new @Snaplet v@ in the current snaplet's state.
putSnapletState :: Snaplet v -> Handler b v ()
putSnapletState = Handler . put


------------------------------------------------------------------------------
-- | Modifies the @Snaplet v@ in the current snaplet's state.
modifySnapletState :: (Snaplet v -> Snaplet v) -> Handler b v ()
modifySnapletState f = do
    s <- getSnapletState
    putSnapletState (f s)


------------------------------------------------------------------------------
-- | Gets the @Snaplet v@ from the current snaplet's state and applies a
-- function to it.
getsSnapletState :: (Snaplet v -> b) -> Handler b1 v b
getsSnapletState f = do
    s <- getSnapletState
    return (f s)


------------------------------------------------------------------------------
-- | Lets you access the current snaplet's state through the 'MonadState'
-- interface.
instance MonadState v (Handler b v) where
    get = getsSnapletState _snapletValue
    put v = modifySnapletState (set snapletValue v)


------------------------------------------------------------------------------
-- | Lets you access the current snaplet's state through the 'MonadReader'
-- interface.
instance MonadReader v (Handler b v) where
    ask = getsSnapletState _snapletValue
    local f m = do
        cur <- ask
        put (f cur)
        res <- m
        put cur
        return res


------------------------------------------------------------------------------
instance MonadSnaplet Handler where
    getLens = Handler ask
    with' !l (Handler !m) = Handler $ L.with l m
    withTop' !l (Handler m) = Handler $ L.withTop l m
    getOpaqueConfig = Handler $ gets _snapletConfig


------------------------------------------------------------------------------
-- | Like 'runBase', but it doesn't require an MVar to be executed.
runPureBase :: Handler b b a -> Snaplet b -> Snap a
runPureBase (Handler m) b = do
        (!a, _) <- L.runLensed m id b
        return $! a


------------------------------------------------------------------------------
-- | Gets the route pattern that matched for the handler.  This lets you find
-- out exactly which of the strings you used in addRoutes matched.
getRoutePattern :: Handler b v (Maybe ByteString)
getRoutePattern =
    withTop' id $ liftM _scRoutePattern getOpaqueConfig


------------------------------------------------------------------------------
-- | Sets the route pattern that matched for the handler.  Use this when to
-- override the default pattern which is the key to the alist passed to
-- addRoutes.
setRoutePattern :: ByteString -> Handler b v ()
setRoutePattern p = withTop' id $
    modifySnapletState (set (snapletConfig . scRoutePattern) (Just p))


------------------------------------------------------------------------------
-- | Check whether the request comes from localhost.
isLocalhost :: MonadSnap m => m Bool
isLocalhost = do
    rip <- liftM rqClientAddr getRequest
    return $ elem rip [ "127.0.0.1"
                      , "localhost"
                      , "::1" ]


------------------------------------------------------------------------------
-- | Pass if the request is not coming from localhost.
failIfNotLocal :: MonadSnap m => m b -> m b
failIfNotLocal m = do
    isLocal <- isLocalhost
    if isLocal then m else pass


------------------------------------------------------------------------------
-- | Handler that reloads the site.
reloadSite :: Handler b v ()
reloadSite = failIfNotLocal $ do
    cfg <- getOpaqueConfig
    !res <- liftIO $ _reloader cfg
    either bad good res
  where
    bad msg = do
        writeText $ "Error reloading site!\n\n"
        writeText msg
    good msg = do
        writeText msg
        writeText $ "Site successfully reloaded.\n"


------------------------------------------------------------------------------
-- | This function brackets a Handler action in resource acquisition and
-- release.  Like 'bracketSnap',  this is provided because MonadCatchIO's
-- 'bracket' function doesn't work properly in the case of a short-circuit
-- return from the action being bracketed.
--
-- In order to prevent confusion regarding the effects of the
-- aquisition and release actions on the Handler state, this function
-- doesn't accept Handler actions for the acquire or release actions.
--
-- This function will run the release action in all cases where the
-- acquire action succeeded.  This includes the following behaviors
-- from the bracketed Snap action.
--
-- 1. Normal completion
--
-- 2. Short-circuit completion, either from calling 'fail' or 'finishWith'
--
-- 3. An exception being thrown.
bracketHandler :: IO a -> (a -> IO x) -> (a -> Handler b v c) -> Handler b v c
bracketHandler begin end f = Handler . L.Lensed $ \l v b -> do
    bracketSnap begin end $ \a -> case f a of Handler m -> L.unlensed m l v b


------------------------------------------------------------------------------
-- | Information about a partially constructed initializer.  Used to
-- automatically aggregate handlers and cleanup actions.
data InitializerState b = InitializerState
    { _isTopLevel      :: Bool
    , _cleanup         :: IORef (IO ())
    , _handlers        :: [(ByteString, Handler b b ())]
        -- ^ Handler routes built up and passed to route.
    , _hFilter         :: Handler b b () -> Handler b b ()
        -- ^ Generic filtering of handlers
    , _curConfig       :: SnapletConfig
        -- ^ This snaplet config is the incrementally built config for
        -- whatever snaplet is currently being constructed.
    , _initMessages    :: IORef Text
    , _environment     :: String
    , masterReloader   :: (Snaplet b -> Snaplet b) -> IO ()
        -- ^ We can't just hae a simple MVar here because MVars can't be
        -- chrooted.
    }


------------------------------------------------------------------------------
-- | Wrapper around IO actions that modify state elements created during
-- initialization.
newtype Hook a = Hook (Snaplet a -> IO (Either Text (Snaplet a)))

instance Semigroup (Hook a) where
    Hook a <> Hook b = Hook $ \s -> do
      ea <- a s
      case ea of
        Left e -> return $ Left e
        Right ares -> do
          eb <- b ares
          case eb of
            Left e -> return $ Left e
            Right bres -> return $ Right bres


------------------------------------------------------------------------------
instance Monoid (Hook a) where
    mempty = Hook (return . Right)
#if !MIN_VERSION_base(4,11,0)
    mappend = (<>)
#endif


------------------------------------------------------------------------------
-- | Monad used for initializing snaplets.
newtype Initializer b v a =
    Initializer (LT.LensT (Snaplet b)
                          (Snaplet v)
                          (InitializerState b)
                          (WriterT (Hook b) IO)
                          a)
  deriving (Applicative, Functor, Monad, MonadIO)

makeLenses ''InitializerState


------------------------------------------------------------------------------
instance MonadSnaplet Initializer where
    getLens = Initializer ask
    with' !l (Initializer !m) = Initializer $ LT.with l m
    withTop' !l (Initializer m) = Initializer $ LT.withTop l m
    getOpaqueConfig = Initializer $ liftM _curConfig LT.getBase


------------------------------------------------------------------------------
-- | Opaque newtype which gives us compile-time guarantees that the user is
-- using makeSnaplet and either nestSnaplet or embedSnaplet correctly.
newtype SnapletInit b v = SnapletInit (Initializer b v (Snaplet v))
