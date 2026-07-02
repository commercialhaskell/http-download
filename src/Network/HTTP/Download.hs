{-# LANGUAGE NoImplicitPrelude  #-}
{-# LANGUAGE OverloadedStrings  #-}

module Network.HTTP.Download
  ( DownloadRequest
  , mkDownloadRequest
  , modifyRequest
  , setHashChecks
  , setLengthCheck
  , setRetryPolicy
  , setForceDownload
  , drRetryPolicyDefault
  , HashCheck (..)
  , DownloadException (..)
  , CheckHexDigest (..)
  , LengthCheck
  , VerifiedDownloadException (..)
  , download
  , redownload
  , verifiedDownload
  ) where

import           Conduit
                   ( (.|), runConduit, withSinkFileCautious, withSourceFile
                   , yield
                   )
import qualified Data.ByteString.Lazy as L
import qualified Data.Conduit.Binary as CB
import           Network.HTTP.Client
                   ( HttpException, Request, Response, checkResponse, path
                   , requestHeaders
                   )
import           Network.HTTP.Download.Verified
                   ( CheckHexDigest (..), DownloadRequest, HashCheck (..)
                   , LengthCheck, VerifiedDownloadException (..)
                   , drRetryPolicyDefault, mkDownloadRequest, modifyRequest
                   , recoveringHttp, setForceDownload, setHashChecks
                   , setLengthCheck, setRetryPolicy, verifiedDownload
                   )
import           Network.HTTP.Simple
                   ( getResponseBody, getResponseHeaders, getResponseStatusCode
                   , withResponse
                   )
import           Path ( Path, Abs, File, toFilePath )
import           Path.IO ( doesFileExist )
import           RIO
import           RIO.PrettyPrint ( HasTerm )
import           System.Directory ( createDirectoryIfMissing, removeFile )
import           System.FilePath ( (<.>), takeDirectory )

-- | Download the given URL to the given location. If the file already exists,
-- no download is performed. Otherwise, creates the parent directory, downloads
-- to a temporary file, and on file download completion moves to the
-- appropriate destination.
--
-- Throws an exception if things go wrong.
download ::
     HasTerm env
  => Request
  -> Path Abs File
     -- ^ Destination.
  -> RIO env Bool
     -- ^ Was a downloaded performed (True) or did the file already exist
     -- (False)?
download req destpath = do
  let downloadReq = mkDownloadRequest req
  let progressHook _ = pure ()
  verifiedDownload downloadReq destpath progressHook

-- | Same as 'download', but will download a file a second time if it is already
-- present.
--
-- Returns 'True' if the file was downloaded, 'False' otherwise.
redownload ::
     HasTerm env
  => Request
  -> Path Abs File -- ^ Destination.
  -> RIO env Bool
redownload req0 dest = do
  logDebug $
       "Downloading "
    <> display (decodeUtf8With lenientDecode (path req0))
  let destFilePath = toFilePath dest
      etagFilePath = destFilePath <.> "etag"

  metag <- do
    exists <- doesFileExist dest
    if not exists
      then pure Nothing
      else
        liftIO $ handleIO (const $ pure Nothing) $ fmap Just $
          withSourceFile etagFilePath $ \src -> runConduit $ src .| CB.take 512

  let req1 =
        case metag of
          Nothing -> req0
          Just etag -> req0
            { requestHeaders =
                   requestHeaders req0
                ++ [("If-None-Match", L.toStrict etag)]
            }
      req2 = req1 { checkResponse = \_ _ -> pure () }
  recoveringHttp drRetryPolicyDefault $ catchingHttpExceptions $ liftIO $
    withResponse req2 $ \res -> case getResponseStatusCode res of
      200 -> do
        createDirectoryIfMissing True $ takeDirectory destFilePath

        -- Order here is important: first delete the etag, then write the
        -- file, then write the etag. That way, if any step fails, it will
        -- force the download to happen again.
        handleIO (const $ pure ()) $ removeFile etagFilePath

        withSinkFileCautious destFilePath $ \sink ->
          runConduit $ getResponseBody res .| sink

        forM_ (lookup "ETag" (getResponseHeaders res)) $ \e ->
          withSinkFileCautious etagFilePath $ \sink ->
            runConduit $ yield e .| sink

        pure True

      304 -> pure False
      _ -> throwM $ RedownloadInvalidResponse req2 dest $ void res
 where
  catchingHttpExceptions :: RIO env a -> RIO env a
  catchingHttpExceptions action = catch action (throwM . RedownloadHttpError)

data DownloadException
  = RedownloadInvalidResponse Request (Path Abs File) (Response ())
  | RedownloadHttpError HttpException
  deriving (Show)

instance Exception DownloadException
