-- |
-- This functionality is not to be considered stable
-- or ready for production use. While we enourage you
-- to try it out and report bugs, we cannot assure you
-- that everything will work as advertised :)

module Colog.Rotation
       ( Limit(..)
       , withLogRotation
       ) where

import Control.Monad (when, (>=>))
import Control.Monad.IO.Class (MonadIO (..))
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List.NonEmpty (nonEmpty)
import Data.Maybe (fromMaybe, mapMaybe)
import Numeric.Natural (Natural)
import System.FilePath.Posix ((<.>))
import System.IO (Handle, IOMode (AppendMode), hClose, hFileSize, openFile)
import Text.Read (readMaybe)

import Colog.Core.Action (LogAction (..), (<&))

import qualified Data.List.NonEmpty as NE
import qualified System.Directory as D
import qualified System.FilePath.Posix as POS


data Limit = LimitTo Natural | Unlimited deriving (Eq, Ord)

{- | Logger rotation action. Takes name of the logging file @file.foo@. Always
writes new logs to file named @file.foo@ (given file name, also called as /hot log/).

* If the size of the file exceeds given limit for file sizes then this action
  renames @file.foo@ to @file.foo.(n + 1)@ (where @n@ is the number of latest
  renamed file).
* If the number of files on the filesystem is bigger than the files number limit
  then the given @FilePath -> IO ()@ action is called on the oldest file. As
  simple solution, you can pass @removeFile@ function to delete old files but
  you can also pass some archiving function if you don't want to lose old logs.
-}
withLogRotation
    :: forall r msg m .
       MonadIO m
    => Limit
    -- ^ Max allowed file size in bytes
    -> Limit
    -- ^ Max allowed number of files to have
    -> FilePath
    -- ^ File path to log
    -> (FilePath -> IO ())
    -- ^ What to do with old files; pass @removeFile@ here for deletion
    -> (Handle -> LogAction m msg)
    -- ^ Action that writes to file handle
    -> (LogAction m msg -> IO r)
    -- ^ Continuation action
    -> IO r
withLogRotation sizeLimit filesLimit path cleanup mkAction cont = do
    -- TODO: figure out how to use bracket to safely manage
    -- possible exceptions
    handle <- openFile path AppendMode
    handleRef <- newIORef handle
    cont $ rotationAction handleRef
  where
    rotationAction :: IORef Handle -> LogAction m msg
    rotationAction refHandle = LogAction $ \msg -> do
        handle <- liftIO $ readIORef refHandle
        mkAction handle <& msg

        isLimitReached <- isFileSizeLimitReached sizeLimit handle
        when isLimitReached $ cleanupAndRotate refHandle

    cleanupAndRotate :: IORef Handle -> m ()
    cleanupAndRotate refHandle = liftIO $ do
      readIORef refHandle >>= hClose
      maxN <- maxFileIndex path
      renameFileToNumber (maxN + 1) path
      oldFiles <- getOldFiles filesLimit path
      mapM_ cleanup oldFiles
      newHandle <- openFile path AppendMode
      writeIORef refHandle newHandle

-- Checks whether an input is strictly larger than the limit
isLimitedBy :: Integer -> Limit -> Bool
isLimitedBy _ Unlimited = False
isLimitedBy size (LimitTo limit)
  | size <= 0 = False
  | otherwise = toInteger limit > size

isFileSizeLimitReached :: forall m . MonadIO m => Limit -> Handle -> m Bool
isFileSizeLimitReached limit handle = liftIO $ do
  fileSize <- hFileSize handle
  pure $ isLimitedBy fileSize limit

-- if you have files node.log.0, node.log.1 and node.log.2 then this function
-- will return `2` if you give it `node.log`
maxFileIndex :: FilePath -> IO Natural
maxFileIndex path = do
  files <- D.listDirectory (POS.takeDirectory path)
  let logFiles = filter (== POS.takeBaseName path) files
  let maxFile = maximum <$> nonEmpty (mapMaybe logFileIndex logFiles)
  pure $ fromMaybe 0 maxFile

-- given number 4 and path `node.log` renames file `node.log` to `node.log.4`
renameFileToNumber :: Natural -> FilePath -> IO ()
renameFileToNumber n path = D.renameFile path (path <.> show n)

-- if you give it name like `node.log.4` then it returns `Just 4`
logFileIndex :: FilePath -> Maybe Natural
logFileIndex path =
    nonEmpty (POS.takeExtension path) >>= readMaybe . NE.tail

-- creates list of files with indices who are older on given Limit than the latest one
getOldFiles :: Limit -> FilePath -> IO [FilePath]
getOldFiles limit path = do
    currentMaxN <- maxFileIndex path
    files <- D.listDirectory (POS.takeDirectory path)
    pure $ mapMaybe (takeFileIndex >=> guardFileIndex currentMaxN) files
  where
    takeFileIndex  :: FilePath -> Maybe (FilePath, Natural)
    takeFileIndex p = (p,) <$> logFileIndex path

    guardFileIndex :: Natural -> (FilePath, Natural) -> Maybe FilePath
    guardFileIndex maxN (p, n)
      | isOldFile maxN n = Nothing
      | otherwise       = Just p

    isOldFile :: Natural -> Natural -> Bool
    isOldFile maxN n = case limit of
                         Unlimited -> False
                         LimitTo l -> n < maxN - l
