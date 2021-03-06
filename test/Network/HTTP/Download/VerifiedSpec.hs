{-# LANGUAGE NoImplicitPrelude #-}
module Network.HTTP.Download.VerifiedSpec (spec) where

import           Control.Retry                  (limitRetries)
import           Crypto.Hash
import           Network.HTTP.Client
import           Network.HTTP.Download.Verified
import           Path
import           Path.IO -- hiding (withSystemTempDir)
import           System.IO (writeFile, readFile)
import           RIO
import           RIO.PrettyPrint
import           RIO.PrettyPrint.StylesUpdate
import           Test.Hspec

-- TODO: share across test files
withTempDir' :: (Path Abs Dir -> IO a) -> IO a
withTempDir' = withSystemTempDir "NHD_VerifiedSpec"

-- | An example path to download the exampleReq.
getExamplePath :: Path Abs Dir -> IO (Path Abs File)
getExamplePath dir = do
    file <- parseRelFile "cabal-install-1.22.4.0.tar.gz"
    return (dir </> file)

-- | An example DownloadRequest that uses a SHA1
exampleReq :: DownloadRequest
exampleReq = fromMaybe (error "exampleReq") $ do
    req <- parseRequest "http://download.fpcomplete.com/stackage-cli/linux64/cabal-install-1.22.4.0.tar.gz"
    return $
      setHashChecks [exampleHashCheck] $
      setLengthCheck (Just exampleLengthCheck) $
      setRetryPolicy (limitRetries 1) $
      mkDownloadRequest req

exampleHashCheck :: HashCheck
exampleHashCheck = HashCheck
    { hashCheckAlgorithm = SHA1
    , hashCheckHexDigest = CheckHexDigestString "b98eea96d321cdeed83a201c192dac116e786ec2"
    }

exampleLengthCheck :: LengthCheck
exampleLengthCheck = 302513

-- | The wrong ContentLength for exampleReq
exampleWrongContentLength :: Int
exampleWrongContentLength = 302512

-- | The wrong SHA1 digest for exampleReq
exampleWrongDigest :: CheckHexDigest
exampleWrongDigest = CheckHexDigestString "b98eea96d321cdeed83a201c192dac116e786ec3"

exampleWrongContent :: String
exampleWrongContent = "example wrong content"

isWrongContentLength :: VerifiedDownloadException -> Bool
isWrongContentLength WrongContentLength{} = True
isWrongContentLength _ = False

isWrongDigest :: VerifiedDownloadException -> Bool
isWrongDigest WrongDigest{} = True
isWrongDigest _ = False

data TestTerm = TestTerm

instance HasLogFunc TestTerm where
  -- ingoring output for now
  logFuncL = lens (const $ mkLogFunc mempty) (\t _ -> t)

instance HasStylesUpdate TestTerm where
  stylesUpdateL = lens (const $ StylesUpdate []) (\t _ -> t)

instance HasTerm TestTerm where
  useColorL = lens (const False) (\t _ -> t)
  termWidthL = lens (const 80) (\t _ -> t)

spec :: Spec
spec = do
  let exampleProgressHook _ = return ()

  describe "verifiedDownload" $ do
    let run func = runRIO TestTerm func
    -- Preconditions:
    -- * the exampleReq server is running
    -- * the test runner has working internet access to it
    it "downloads the file correctly" $ withTempDir' $ \dir -> do
      examplePath <- getExamplePath dir
      doesFileExist examplePath `shouldReturn` False
      let go = run $ verifiedDownload exampleReq examplePath exampleProgressHook
      go `shouldReturn` True
      doesFileExist examplePath `shouldReturn` True

    it "is idempotent, and doesn't redownload unnecessarily" $ withTempDir' $ \dir -> do
      examplePath <- getExamplePath dir
      doesFileExist examplePath `shouldReturn` False
      let go = run $ verifiedDownload exampleReq examplePath exampleProgressHook
      go `shouldReturn` True
      doesFileExist examplePath `shouldReturn` True
      go `shouldReturn` False
      doesFileExist examplePath `shouldReturn` True

    -- https://github.com/commercialhaskell/stack/issues/372
    it "does redownload when the destination file is wrong" $ withTempDir' $ \dir -> do
      examplePath <- getExamplePath dir
      let exampleFilePath = toFilePath examplePath
      writeFile exampleFilePath exampleWrongContent
      doesFileExist examplePath `shouldReturn` True
      readFile exampleFilePath `shouldReturn` exampleWrongContent
      let go = run $ verifiedDownload exampleReq examplePath exampleProgressHook
      go `shouldReturn` True
      doesFileExist examplePath `shouldReturn` True
      readFile exampleFilePath `shouldNotReturn` exampleWrongContent

    it "rejects incorrect content length" $ withTempDir' $ \dir -> do
      examplePath <- getExamplePath dir
      let wrongContentLengthReq = setLengthCheck (Just exampleWrongContentLength) exampleReq
      let go = run $ verifiedDownload wrongContentLengthReq examplePath exampleProgressHook
      go `shouldThrow` isWrongContentLength
      doesFileExist examplePath `shouldReturn` False

    it "rejects incorrect digest" $ withTempDir' $ \dir -> do
      examplePath <- getExamplePath dir
      let wrongHashCheck = exampleHashCheck { hashCheckHexDigest = exampleWrongDigest }
      let wrongDigestReq = setHashChecks [wrongHashCheck] exampleReq
      let go = run $ verifiedDownload wrongDigestReq examplePath exampleProgressHook
      go `shouldThrow` isWrongDigest
      doesFileExist examplePath `shouldReturn` False

    -- https://github.com/commercialhaskell/stack/issues/240
    it "can download hackage tarballs" $ withTempDir' $ \dir -> do
      dest <- (dir </>) <$> parseRelFile "acme-missiles-0.3.tar.gz"
      req <- parseRequest "http://hackage.haskell.org/package/acme-missiles-0.3/acme-missiles-0.3.tar.gz"
      let dReq = setRetryPolicy (limitRetries 1) $ mkDownloadRequest req
      let go = run $ verifiedDownload dReq dest exampleProgressHook
      doesFileExist dest `shouldReturn` False
      go `shouldReturn` True
      doesFileExist dest `shouldReturn` True

    it "does redownload when forceDownload is True" $ withTempDir' $ \dir -> do
      examplePath <- getExamplePath dir
      doesFileExist examplePath `shouldReturn` False
      let go = run $ verifiedDownload exampleReq examplePath exampleProgressHook
      go `shouldReturn` True
      doesFileExist examplePath `shouldReturn` True

      let forceReq = setForceDownload True exampleReq
      let go' = run $ verifiedDownload forceReq examplePath exampleProgressHook
      go' `shouldReturn` True
      doesFileExist examplePath `shouldReturn` True
