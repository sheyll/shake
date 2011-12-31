
-- | A module for 'FilePath' operations, to be used instead of "System.FilePath"
--   when writing build systems. In build systems, when using the file name
--   as a key for indexing rules, it is important that two different strings do
--   not refer to the same on-disk file. We therefore follow the conventions:
--
-- * Always use @\/@ as the directory separator, even on Windows.
--
-- * When combining 'FilePath' values with '</>' we squash any @\/.\/@ components.
module Development.Shake.FilePath(
    module System.FilePath.Posix,
    dropDirectory1, takeDirectory1, normalise,
    toNative, (</>), combine,
    ) where

import System.FilePath.Posix hiding (isPathSeparator, normalise, (</>), combine)
import qualified System.FilePath as Native


-- | Drop the first directory from a 'FilePath'. Should only be used on
--   relative paths.
--
-- > dropDirectory1 "aaa/bbb" == "bbb"
-- > dropDirectory1 "aaa/" == ""
-- > dropDirectory1 "aaa" == ""
-- > dropDirectory1 "" == ""
dropDirectory1 :: FilePath -> FilePath
dropDirectory1 = drop 1 . dropWhile (not . Native.isPathSeparator)


-- | Take the first component of a 'FilePath'. Should only be used on
--   relative paths.
--
-- > takeDirectory1 "aaa/bbb" == "aaa"
-- > takeDirectory1 "aaa/" == "aaa"
-- > takeDirectory1 "aaa" == "aaa"
takeDirectory1 :: FilePath -> FilePath
takeDirectory1 = takeWhile (not . Native.isPathSeparator)


-- | Normalise a 'FilePath', translating any path separators to @\/@.
normalise :: FilePath -> FilePath
normalise = map (\x -> if Native.isPathSeparator x then '/' else x)


-- | Convert to native path separators, namely @\\@ on Windows. 
toNative :: FilePath -> FilePath
toNative = map (\x -> if Native.isPathSeparator x then Native.pathSeparator else x)


-- | Combine two file paths, an alias for 'combine'.
(</>) :: FilePath -> FilePath -> FilePath
(</>) = combine


-- | Combine two file paths. Any leading @.\/@ or @..\/@ components in the right file
--   are eliminated.
--
-- > combine "aaa/bbb" "ccc" == "aaa/bbb/ccc"
-- > combine "aaa/bbb" "./ccc" == "aaa/bbb/ccc"
-- > combine "aaa/bbb" "../ccc" == "aaa/ccc"
combine :: FilePath -> FilePath -> FilePath
combine x ('.':'.':'/':y) = combine (takeDirectory x) y
combine x ('.':'/':y) = combine x y
combine x y = normalise $ Native.combine (toNative x) (toNative y)
