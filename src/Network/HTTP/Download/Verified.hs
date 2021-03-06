{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE DeriveDataTypeable    #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE StandaloneDeriving    #-}
module Network.HTTP.Download.Verified
  ( verifiedDownload
  , recoveringHttp
  , drRetryPolicyDefault
  , HashCheck(..)
  , CheckHexDigest(..)
  , LengthCheck
  , VerifiedDownloadException(..)
  -- * DownloadRequest construction
  , DownloadRequest
  , mkDownloadRequest
  , modifyRequest
  , setHashChecks
  , setLengthCheck
  , setRetryPolicy
  , setForceDownload
  ) where

import qualified    Data.List as List
import qualified    Data.ByteString.Base64 as B64
import              Conduit (sinkHandle)
import qualified    Data.Conduit.Binary as CB
import qualified    Data.Conduit.List as CL

import              Control.Monad
import              Control.Monad.Catch (Handler (..)) -- would be nice if retry exported this itself
import              Control.Retry (recovering,limitRetries,RetryPolicy,exponentialBackoff,RetryStatus(..))
import              Crypto.Hash
import              Crypto.Hash.Conduit (sinkHash)
import              Data.ByteArray as Mem (convert)
import              Data.ByteArray.Encoding as Mem (convertToBase, Base(Base16))
import              Data.ByteString.Char8 (readInteger)
import              Data.Conduit
import              Data.Conduit.Binary (sourceHandle)
import              Data.Monoid (Sum(..))
import              GHC.IO.Exception (IOException(..),IOErrorType(..))
import              Network.HTTP.Client (Request, HttpException, getUri, path)
import              Network.HTTP.Simple (getResponseHeaders, httpSink)
import              Network.HTTP.Types (hContentLength, hContentMD5)
import              Path
import              RIO hiding (Handler)
import              RIO.PrettyPrint
import qualified    RIO.ByteString as ByteString
import qualified    RIO.Text as Text
import              System.Directory
import qualified    System.FilePath as FP
import              System.IO (openTempFileWithDefaultPermissions)

-- | A request together with some checks to perform.
--
-- Construct using the 'downloadRequest' smart constructor and associated
-- setters. The constructor itself is not exposed to avoid breaking changes
-- with additional fields.
--
-- @since 0.2.0.0
data DownloadRequest = DownloadRequest
    { drRequest :: Request
    , drHashChecks :: [HashCheck]
    , drLengthCheck :: Maybe LengthCheck
    , drRetryPolicy :: RetryPolicy
    , drForceDownload :: Bool -- ^ whether to redownload or not if file exists
    }

-- | Construct a new 'DownloadRequest' from the given 'Request'. Use associated
-- setters to modify the value further.
--
-- @since 0.2.0.0
mkDownloadRequest :: Request -> DownloadRequest
mkDownloadRequest req = DownloadRequest req [] Nothing drRetryPolicyDefault False

-- | Modify the 'Request' inside a 'DownloadRequest'. Especially intended for modifying the @User-Agent@ request header.
--
-- @since 0.2.0.0
modifyRequest :: (Request -> Request) -> DownloadRequest -> DownloadRequest
modifyRequest f dr = dr { drRequest = f $ drRequest dr }

-- | Set the hash checks to be run when verifying.
--
-- @since 0.2.0.0
setHashChecks :: [HashCheck] -> DownloadRequest -> DownloadRequest
setHashChecks x dr = dr { drHashChecks = x }

-- | Set the length check to be run when verifying.
--
-- @since 0.2.0.0
setLengthCheck :: Maybe LengthCheck -> DownloadRequest -> DownloadRequest
setLengthCheck x dr = dr { drLengthCheck = x }

-- | Set the retry policy to be used when downloading.
--
-- @since 0.2.0.0
setRetryPolicy :: RetryPolicy -> DownloadRequest -> DownloadRequest
setRetryPolicy x dr = dr { drRetryPolicy = x }

-- | If 'True', force download even if the file already exists. Useful for
-- download a resource which may change over time.
setForceDownload :: Bool -> DownloadRequest -> DownloadRequest
setForceDownload x dr = dr { drForceDownload = x }

-- | Default to retrying seven times with exponential backoff starting from
-- one hundred milliseconds.
--
-- This means the tries will occur after these delays if necessary:
--
-- * 0.1s
-- * 0.2s
-- * 0.4s
-- * 0.8s
-- * 1.6s
-- * 3.2s
-- * 6.4s
drRetryPolicyDefault :: RetryPolicy
drRetryPolicyDefault = limitRetries 7 <> exponentialBackoff onehundredMilliseconds
  where onehundredMilliseconds = 100000

data HashCheck = forall a. (Show a, HashAlgorithm a) => HashCheck
  { hashCheckAlgorithm :: a
  , hashCheckHexDigest :: CheckHexDigest
  }
deriving instance Show HashCheck

data CheckHexDigest
  = CheckHexDigestString String
  | CheckHexDigestByteString ByteString
  | CheckHexDigestHeader ByteString
  deriving Show
instance IsString CheckHexDigest where
  fromString = CheckHexDigestString

type LengthCheck = Int

-- | An exception regarding verification of a download.
data VerifiedDownloadException
    = WrongContentLength
          Request
          Int -- expected
          ByteString -- actual (as listed in the header)
    | WrongStreamLength
          Request
          Int -- expected
          Int -- actual
    | WrongDigest
          Request
          String -- algorithm
          CheckHexDigest -- expected
          String -- actual (shown)
    | DownloadHttpError
          HttpException
  deriving (Typeable)
instance Show VerifiedDownloadException where
    show (WrongContentLength req expected actual) =
        "Download expectation failure: ContentLength header\n"
        ++ "Expected: " ++ show expected ++ "\n"
        ++ "Actual:   " ++ displayByteString actual ++ "\n"
        ++ "For: " ++ show (getUri req)
    show (WrongStreamLength req expected actual) =
        "Download expectation failure: download size\n"
        ++ "Expected: " ++ show expected ++ "\n"
        ++ "Actual:   " ++ show actual ++ "\n"
        ++ "For: " ++ show (getUri req)
    show (WrongDigest req algo expected actual) =
        "Download expectation failure: content hash (" ++ algo ++  ")\n"
        ++ "Expected: " ++ displayCheckHexDigest expected ++ "\n"
        ++ "Actual:   " ++ actual ++ "\n"
        ++ "For: " ++ show (getUri req)
    show (DownloadHttpError exception) =
      "Download expectation failure: " ++ show exception

instance Exception VerifiedDownloadException

-- This exception is always caught and never thrown outside of this module.
data VerifyFileException
    = WrongFileSize
          Int -- expected
          Integer -- actual (as listed by hFileSize)
  deriving (Show, Typeable)
instance Exception VerifyFileException

-- Show a ByteString that is known to be UTF8 encoded.
displayByteString :: ByteString -> String
displayByteString =
    Text.unpack . Text.strip . decodeUtf8Lenient

-- Show a CheckHexDigest in human-readable format.
displayCheckHexDigest :: CheckHexDigest -> String
displayCheckHexDigest (CheckHexDigestString s) = s ++ " (String)"
displayCheckHexDigest (CheckHexDigestByteString s) = displayByteString s ++ " (ByteString)"
displayCheckHexDigest (CheckHexDigestHeader h) =
      show (B64.decodeLenient h) ++ " (Header. unencoded: " ++ show h ++ ")"


-- | Make sure that the hash digest for a finite stream of bytes
-- is as expected.
--
-- Throws WrongDigest (VerifiedDownloadException)
sinkCheckHash :: MonadThrow m
    => Request
    -> HashCheck
    -> ConduitM ByteString o m ()
sinkCheckHash req HashCheck{..} = do
    digest <- sinkHashUsing hashCheckAlgorithm
    let actualDigestString = show digest
    let actualDigestHexByteString = Mem.convertToBase Mem.Base16 digest
    let actualDigestBytes = Mem.convert digest

    let passedCheck = case hashCheckHexDigest of
          CheckHexDigestString s -> s == actualDigestString
          CheckHexDigestByteString b -> b == actualDigestHexByteString
          CheckHexDigestHeader b -> B64.decodeLenient b == actualDigestHexByteString
            || B64.decodeLenient b == actualDigestBytes
            -- A hack to allow hackage tarballs to download.
            -- They should really base64-encode their md5 header as per rfc2616#sec14.15.
            -- https://github.com/commercialhaskell/stack/issues/240
            || b == actualDigestHexByteString

    unless passedCheck $
        throwM $ WrongDigest req (show hashCheckAlgorithm) hashCheckHexDigest actualDigestString

assertLengthSink :: MonadThrow m
    => Request
    -> LengthCheck
    -> ZipSink ByteString m ()
assertLengthSink req expectedStreamLength = ZipSink $ do
  Sum actualStreamLength <- CL.foldMap (Sum . ByteString.length)
  when (actualStreamLength /= expectedStreamLength) $
    throwM $ WrongStreamLength req expectedStreamLength actualStreamLength

-- | A more explicitly type-guided sinkHash.
sinkHashUsing :: (Monad m, HashAlgorithm a) => a -> ConduitM ByteString o m (Digest a)
sinkHashUsing _ = sinkHash

-- | Turns a list of hash checks into a ZipSink that checks all of them.
hashChecksToZipSink :: MonadThrow m => Request -> [HashCheck] -> ZipSink ByteString m ()
hashChecksToZipSink req = traverse_ (ZipSink . sinkCheckHash req)

-- 'Control.Retry.recovering' customized for HTTP failures
recoveringHttp :: forall env a. HasTerm env => RetryPolicy -> RIO env a -> RIO env a
recoveringHttp retryPolicy =
    helper $ \run -> recovering retryPolicy (handlers run) . const
  where
    helper :: (UnliftIO (RIO env) -> IO a -> IO a) -> RIO env a -> RIO env a
    helper wrapper action = withUnliftIO $ \run -> wrapper run (unliftIO run action)

    handlers :: UnliftIO (RIO env) -> [RetryStatus -> Handler IO Bool]
    handlers u = [Handler . alwaysRetryHttp u,const $ Handler retrySomeIO]

    alwaysRetryHttp :: UnliftIO (RIO env) -> RetryStatus -> HttpException -> IO Bool
    alwaysRetryHttp u rs _ = do
      unliftIO u $
        prettyWarn $ vcat
          [ flow $ unwords
            [ "Retry number"
            , show (rsIterNumber rs)
            , "after a total delay of"
            , show (rsCumulativeDelay rs)
            , "us"
            ]
          , flow $ unwords
            [ "If you see this warning and stack fails to download,"
            , "but running the command again solves the problem,"
            , "please report here: https://github.com/commercialhaskell/stack/issues/3510"
            , "Make sure to paste the output of 'stack --version'"
            ]
          ]
      return True

    retrySomeIO :: Monad m => IOException -> m Bool
    retrySomeIO e = return $ case ioe_type e of
                               -- hGetBuf: resource vanished (Connection reset by peer)
                               ResourceVanished -> True
                               -- conservatively exclude all others
                               _ -> False

-- | Copied and extended version of Network.HTTP.Download.download.
--
-- Has the following additional features:
-- * Verifies that response content-length header (if present)
--     matches expected length
-- * Limits the download to (close to) the expected # of bytes
-- * Verifies that the expected # bytes were downloaded (not too few)
-- * Verifies md5 if response includes content-md5 header
-- * Verifies the expected hashes
--
-- Throws VerifiedDownloadException.
-- Throws IOExceptions related to file system operations.
-- Throws HttpException.
verifiedDownload
         :: HasTerm env
         => DownloadRequest
         -> Path Abs File -- ^ destination
         -> (Maybe Integer -> ConduitM ByteString Void (RIO env) ()) -- ^ custom hook to observe progress
         -> RIO env Bool -- ^ Whether a download was performed
verifiedDownload DownloadRequest{..} destpath progressSink = do
    let req = drRequest
    whenM' (liftIO getShouldDownload) $ do
        logDebug $ "Downloading " <> display (decodeUtf8With lenientDecode (path req))
        liftIO $ createDirectoryIfMissing True dir
        withTempFileWithDefaultPermissions dir (FP.takeFileName fp) $ \fptmp htmp -> do
            recoveringHttp drRetryPolicy $ catchingHttpExceptions $
                httpSink req $ go (sinkHandle htmp)
            hClose htmp
            liftIO $ renameFile fptmp fp
  where
    whenM' mp m = do
        p <- mp
        if p then m >> return True else return False

    fp = toFilePath destpath
    dir = toFilePath $ parent destpath

    getShouldDownload = if drForceDownload then return True else do
        fileExists <- doesFileExist fp
        if fileExists
            -- only download if file does not match expectations
            then not <$> fileMatchesExpectations
            -- or if it doesn't exist yet
            else return True

    -- precondition: file exists
    -- TODO: add logging
    fileMatchesExpectations =
        ((checkExpectations >> return True)
          `catch` \(_ :: VerifyFileException) -> return False)
          `catch` \(_ :: VerifiedDownloadException) -> return False

    checkExpectations = withBinaryFile fp ReadMode $ \h -> do
        for_ drLengthCheck $ checkFileSizeExpectations h
        runConduit
            $ sourceHandle h
           .| getZipSink (hashChecksToZipSink drRequest drHashChecks)

    -- doesn't move the handle
    checkFileSizeExpectations h expectedFileSize = do
        fileSizeInteger <- hFileSize h
        when (fileSizeInteger > toInteger (maxBound :: Int)) $
            throwM $ WrongFileSize expectedFileSize fileSizeInteger
        let fileSize = fromInteger fileSizeInteger
        when (fileSize /= expectedFileSize) $
            throwM $ WrongFileSize expectedFileSize fileSizeInteger

    checkContentLengthHeader headers expectedContentLength =
        case List.lookup hContentLength headers of
            Just lengthBS -> do
              let lengthStr = displayByteString lengthBS
              when (lengthStr /= show expectedContentLength) $
                throwM $ WrongContentLength drRequest expectedContentLength lengthBS
            _ -> return ()

    go sink res = do
        let headers = getResponseHeaders res
            mcontentLength = do
              hLength <- List.lookup hContentLength headers
              (i,_) <- readInteger hLength
              return i
        for_ drLengthCheck $ checkContentLengthHeader headers
        let hashChecks = (case List.lookup hContentMD5 headers of
                Just md5BS ->
                    [ HashCheck
                          { hashCheckAlgorithm = MD5
                          , hashCheckHexDigest = CheckHexDigestHeader md5BS
                          }
                    ]
                Nothing -> []
                ) ++ drHashChecks

        maybe id (\len -> (CB.isolate len .|)) drLengthCheck
            $ getZipSink
                ( hashChecksToZipSink drRequest hashChecks
                  *> maybe (pure ()) (assertLengthSink drRequest) drLengthCheck
                  *> ZipSink sink
                  *> ZipSink (progressSink mcontentLength))
    catchingHttpExceptions :: RIO env a -> RIO env a
    catchingHttpExceptions action = catch action (throwM . DownloadHttpError)


-- | Like 'UnliftIO.Temporary.withTempFile', but the file is created with
--   default file permissions, instead of read/write access only for the owner.
withTempFileWithDefaultPermissions
             :: MonadUnliftIO m
             => FilePath -- ^ Temp dir to create the file in.
             -> String   -- ^ File name template. See 'openTempFile'.
             -> (FilePath -> Handle -> m a) -- ^ Callback that can use the file.
             -> m a
withTempFileWithDefaultPermissions tmpDir template action =
  bracket
    (liftIO (openTempFileWithDefaultPermissions tmpDir template))
    (\(name, handle') -> liftIO (hClose handle' >> ignoringIOErrors (removeFile name)))
    (uncurry action)
  where
    ignoringIOErrors = void. tryIO
