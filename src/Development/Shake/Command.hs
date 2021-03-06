{-# LANGUAGE FlexibleInstances, TypeSynonymInstances, TypeOperators, ScopedTypeVariables #-}

-- | This module provides functions for calling command line programs, primarily
--   'command' and 'cmd'. As a simple example:
--
-- @
-- 'command' [] \"gcc\" [\"-c\",myfile]
-- @
--
--   The functions from this module are now available directly from "Development.Shake".
--   You should only need to import this module if you are using the 'cmd' function in the 'IO' monad.
module Development.Shake.Command(
    command, command_, cmd, unit, CmdArguments,
    Stdout(..), Stderr(..), Stdouterr(..), Exit(..), CmdTime(..), CmdLine(..),
    CmdResult, CmdString, CmdOption(..),
    addPath, addEnv,
    ) where

import Data.Tuple.Extra
import Control.Applicative
import Control.Exception.Extra
import Control.Monad.Extra
import Control.Monad.IO.Class
import Data.Either
import Data.List.Extra
import Data.Maybe
import System.Directory
import System.Environment.Extra
import System.Exit
import System.IO.Extra
import System.Process
import System.Info.Extra
import System.Time.Extra
import System.IO.Unsafe(unsafeInterleaveIO)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy.Char8 as LBS
import General.Process

import Development.Shake.Core
import Development.Shake.FilePath
import Development.Shake.Types
import Development.Shake.Rules.File


---------------------------------------------------------------------
-- ACTUAL EXECUTION

-- | Options passed to 'command' or 'cmd' to control how processes are executed.
data CmdOption
    = Cwd FilePath -- ^ Change the current directory in the spawned process. By default uses this processes current directory.
    | Env [(String,String)] -- ^ Change the environment variables in the spawned process. By default uses this processes environment.
                            --   Use 'addPath' to modify the @$PATH@ variable, or 'addEnv' to modify other variables.
    | Stdin String -- ^ Given as the @stdin@ of the spawned process. By default the @stdin@ is inherited.
    | Shell -- ^ Pass the command to the shell without escaping - any arguments will be joined with spaces. By default arguments are escaped properly.
    | BinaryPipes -- ^ Treat the @stdin@\/@stdout@\/@stderr@ messages as binary. By default 'String' results use text encoding and 'ByteString' results use binary encoding.
    | Traced String -- ^ Name to use with 'traced', or @\"\"@ for no tracing. By default traces using the name of the executable.
    | Timeout Double -- ^ Abort the computation after N seconds, will raise a failure exit code.
    | WithStdout Bool -- ^ Should I include the @stdout@ in the exception if the command fails? Defaults to 'False'.
    | WithStderr Bool -- ^ Should I include the @stderr@ in the exception if the command fails? Defaults to 'True'.
    | EchoStdout Bool -- ^ Should I echo the @stdout@? Defaults to 'True' unless a 'Stdout' result is required or you use 'FileStdout'.
    | EchoStderr Bool -- ^ Should I echo the @stderr@? Defaults to 'True' unless a 'Stderr' result is required or you use 'FileStderr'.
    | FileStdout FilePath -- ^ Should I put the @stdout@ to a file.
    | FileStderr FilePath -- ^ Should I put the @stderr@ to a file.
      deriving (Eq,Ord,Show)


-- | Produce a 'CmdOption' of value 'Env' that is the current environment, plus a
--   prefix and suffix to the @$PATH@ environment variable. For example:
--
-- @
-- opt <- 'addPath' [\"\/usr\/special\"] []
-- 'cmd' opt \"userbinary --version\"
-- @
--
--   Would prepend @\/usr\/special@ to the current @$PATH@, and the command would pick
--   @\/usr\/special\/userbinary@, if it exists. To add other variables see 'addEnv'.
addPath :: MonadIO m => [String] -> [String] -> m CmdOption
addPath pre post = do
    args <- liftIO getEnvironment
    let (path,other) = partition ((== "PATH") . (if isWindows then upper else id) . fst) args
    return $ Env $
        [("PATH",intercalate [searchPathSeparator] $ pre ++ post) | null path] ++
        [(a,intercalate [searchPathSeparator] $ pre ++ [b | b /= ""] ++ post) | (a,b) <- path] ++
        other

-- | Produce a 'CmdOption' of value 'Env' that is the current environment, plus the argument
--   environment variables. For example:
--
-- @
-- opt <- 'addEnv' [(\"CFLAGS\",\"-O2\")]
-- 'cmd' opt \"gcc -c main.c\"
-- @
--
--   Would add the environment variable @$CFLAGS@ with value @-O2@. If the variable @$CFLAGS@
--   was already defined it would be overwritten. If you wish to modify @$PATH@ see 'addPath'.
addEnv :: MonadIO m => [(String, String)] -> m CmdOption
addEnv extra = do
    args <- liftIO getEnvironment
    return $ Env $ extra ++ filter (\(a,b) -> a `notElem` map fst extra) args

data Str = Str String | BS BS.ByteString | LBS LBS.ByteString | Unit deriving Eq

data Result
    = ResultStdout Str
    | ResultStderr Str
    | ResultStdouterr Str
    | ResultCode ExitCode
    | ResultTime Double
    | ResultLine String
      deriving Eq


---------------------------------------------------------------------
-- ACTION EXPLICIT OPERATION

commandExplicit :: String -> [CmdOption] -> [Result] -> String -> [String] -> Action [Result]
commandExplicit funcName copts results exe args = do
    opts <- getShakeOptions
    verb <- getVerbosity

    let skipper act = if null results && not (shakeRunCommands opts) then return [] else act

    let verboser act = do
            let cwd = listToMaybe $ reverse [x | Cwd x <- copts]
            putLoud $ maybe "" (\x -> "cd " ++ x ++ "; ") cwd ++ saneCommandForUser exe args
            (if verb >= Loud then quietly else id) act

    let tracer = case reverse [x | Traced x <- copts] of
            "":_ -> liftIO
            msg:_ -> traced msg
            [] -> traced (takeFileName exe)

    let tracker act = case shakeLint opts of
            Just LintTracker -> do
                dir <- liftIO $ getTemporaryDirectory
                (file, handle) <- liftIO $ openTempFile dir "shake.lint"
                liftIO $ hClose handle
                dir <- return $ file <.> "dir"
                liftIO $ createDirectory dir
                let cleanup = removeDirectoryRecursive dir >> removeFile file
                flip actionFinally cleanup $ do
                    res <- act "tracker" $ "/if":dir:"/c":exe:args
                    (read,write) <- liftIO $ trackerFiles dir
                    trackRead read
                    trackWrite write
                    return res
            _ -> act exe args

    skipper $ tracker $ \exe args -> verboser $ tracer $ commandExplicitIO funcName copts results exe args


-- | Given a directory (as passed to tracker /if) report on which files were used for reading/writing
trackerFiles :: FilePath -> IO ([FilePath], [FilePath])
trackerFiles dir = do
    curdir <- getCurrentDirectory
    let pre = upper curdir ++ "\\"
    files <- getDirectoryContents dir
    let f typ = do
            files <- forM [x | x <- files, takeExtension x == ".tlog", takeExtension (dropExtension $ dropExtension x) == '.':typ] $ \file -> do
                xs <- readFileEncoding utf16 $ dir </> file
                return $ filter (not . isPrefixOf "." . takeFileName) . mapMaybe (stripPrefix pre) $ lines xs
            fmap nubOrd $ mapMaybeM correctCase $ nubOrd $ concat files
    liftM2 (,) (f "read") (f "write")


correctCase :: FilePath -> IO (Maybe FilePath)
correctCase x = f "" x
    where
        f pre "" = return $ Just pre
        f pre x = do
            let (a,b) = (takeDirectory1 x, dropDirectory1 x)
            dir <- getDirectoryContents pre
            case find ((==) a . upper) dir of
                Nothing -> return Nothing -- if it can't be found it probably doesn't exist, so assume a file that wasn't really read
                Just v -> f (pre +/+ v) b

        a +/+ b = if null a then b else a ++ "/" ++ b


---------------------------------------------------------------------
-- IO EXPLICIT OPERATION

commandExplicitIO :: String -> [CmdOption] -> [Result] -> String -> [String] -> IO [Result]
commandExplicitIO funcName opts results exe args = do
    let (grabStdout, grabStderr) = both or $ unzip $ for results $ \r -> case r of
            ResultStdout{} -> (True, False)
            ResultStderr{} -> (False, True)
            ResultStdouterr{} -> (True, True)
            _ -> (False, False)

    let optCwd = let x = last $ "" : [x | Cwd x <- opts] in if x == "" then Nothing else Just x
    let optEnv = let x = [x | Env x <- opts] in if null x then Nothing else Just $ concat x
    let optStdin = concat [x | Stdin x <- opts]
    let optShell = Shell `elem` opts
    let optBinary = BinaryPipes `elem` opts
    let optTimeout = listToMaybe $ reverse [x | Timeout x <- opts]
    let optWithStdout = last $ False : [x | WithStdout x <- opts]
    let optWithStderr = last $ True : [x | WithStderr x <- opts]
    let optFileStdout = [x | FileStdout x <- opts]
    let optFileStderr = [x | FileStderr x <- opts]
    let optEchoStdout = last $ (not grabStdout && null optFileStdout) : [x | EchoStdout x <- opts]
    let optEchoStderr = last $ (not grabStderr && null optFileStderr) : [x | EchoStderr x <- opts]

    let cmdline = saneCommandForUser exe args
    let bufLBS f = do (a,b) <- buf $ LBS LBS.empty; return (a, (\(LBS x) -> f x) <$> b)
        buf Str{} | optBinary = bufLBS (Str . LBS.unpack)
        buf Str{} = do x <- newBuffer; return ([DestString x], Str . concat <$> readBuffer x)
        buf LBS{} = do x <- newBuffer; return ([DestBytes x], LBS . LBS.fromChunks <$> readBuffer x)
        buf BS {} = bufLBS (BS . BS.concat . LBS.toChunks)
        buf Unit  = return ([], return Unit)
    (dStdout, dStderr, resultBuild) :: ([[Destination]], [[Destination]], [Double -> ExitCode -> IO Result]) <-
        fmap unzip3 $ forM results $ \r -> case r of
            ResultCode _ -> return ([], [], \dur ex -> return $ ResultCode ex)
            ResultTime _ -> return ([], [], \dur ex -> return $ ResultTime dur)
            ResultLine _ -> return ([], [], \dur ex -> return $ ResultLine cmdline)
            ResultStdout    s -> do (a,b) <- buf s; return (a , [], \_ _ -> fmap ResultStdout b)
            ResultStderr    s -> do (a,b) <- buf s; return ([], a , \_ _ -> fmap ResultStderr b)
            ResultStdouterr s -> do (a,b) <- buf s; return (a , a , \_ _ -> fmap ResultStdouterr b)

    exceptionBuffer <- newBuffer
    po <- resolvePath $ ProcessOpts
        {poCommand = if optShell then ShellCommand $ unwords $ exe:args else RawCommand exe args
        ,poCwd = optCwd, poEnv = optEnv, poTimeout = optTimeout
        ,poStdin = if optBinary then Right $ LBS.pack optStdin else Left optStdin
        ,poStdout = [DestEcho | optEchoStdout] ++ map DestFile optFileStdout ++ [DestString exceptionBuffer | optWithStdout] ++ concat dStdout
        ,poStderr = [DestEcho | optEchoStderr] ++ map DestFile optFileStderr ++ [DestString exceptionBuffer | optWithStderr] ++ concat dStderr
        }
    res <- try_ $ duration $ process po

    let failure extra = do
            cwd <- case optCwd of
                Nothing -> return ""
                Just v -> do
                    v <- canonicalizePath v `catch_` const (return v)
                    return $ "Current directory: " ++ v ++ "\n"
            fail $
                "Development.Shake." ++ funcName ++ ", system command failed\n" ++
                "Command: " ++ cmdline ++ "\n" ++
                cwd ++ extra
    case res of
        Left err -> failure $ show err
        Right (dur,ex) | ex /= ExitSuccess && ResultCode ExitSuccess `notElem` results -> do
            exceptionBuffer <- readBuffer exceptionBuffer
            let captured = ["Stderr" | optWithStderr] ++ ["Stdout" | optWithStdout]
            failure $
                "Exit code: " ++ show (case ex of ExitFailure i -> i; _ -> 0) ++ "\n" ++
                if null captured then "Stderr not captured because WithStderr False was used\n"
                else if null exceptionBuffer then intercalate " and " captured ++ " " ++ (if length captured == 1 then "was" else "were") ++ " empty"
                else intercalate " and " captured ++ ":\n" ++ unlines (dropWhile null $ lines $ concat exceptionBuffer)
        Right (dur,ex) -> mapM (\f -> f dur ex) resultBuild


-- | If the user specifies a custom $PATH, and not Shell, then try and resolve their exe ourselves.
--   Tricky, because on Windows it doesn't look in the $PATH first.
resolvePath :: ProcessOpts -> IO ProcessOpts
resolvePath po
    | Just e <- poEnv po
    , Just (_, path) <- find ((==) "PATH" . (if isWindows then upper else id) . fst) e
    , RawCommand prog args <- poCommand po
    = do
    let progExe = if prog == prog -<.> exe then prog else prog <.> exe
    -- use unsafeInterleaveIO to allow laziness to skip the queries we don't use
    pathOld <- unsafeInterleaveIO $ fmap (fromMaybe "") $ lookupEnv "PATH"
    old <- unsafeInterleaveIO $ findExecutable prog
    new <- unsafeInterleaveIO $ findExecutableWith (splitSearchPath path) progExe
    old2 <- unsafeInterleaveIO $ findExecutableWith (splitSearchPath pathOld) progExe

    switch <- return $ case () of
        _ | path == pathOld -> False -- The state I can see hasn't changed
          | Nothing <- new -> False -- I have nothing to offer
          | Nothing <- old -> True -- I failed last time, so this must be an improvement
          | Just old <- old, Just new <- new, equalFilePath old new -> False -- no different
          | Just old <- old, Just old2 <- old2, equalFilePath old old2 -> True -- I could predict last time
          | otherwise -> False
    return $ case new of
        Just new | switch -> po{poCommand = RawCommand new args}
        _ -> po
resolvePath po = return po


findExecutableWith :: [FilePath] -> String -> IO (Maybe FilePath)
findExecutableWith path x = flip firstJustM (map (</> x) path) $ \s ->
    ifM (doesFileExist s) (return $ Just s) (return Nothing)


-- Like System.Process, but tweaked to show less escaping,
-- Relies on relatively detailed internals of showCommandForUser.
saneCommandForUser :: FilePath -> [String] -> String
saneCommandForUser cmd args = unwords $ map f $ cmd:args
    where
        f x = if take (length y - 2) (drop 1 y) == x then x else y
            where y = showCommandForUser x []


---------------------------------------------------------------------
-- FIXED ARGUMENT WRAPPER

-- | Collect the @stdout@ of the process.
--   If used, the @stdout@ will not be echoed to the terminal, unless you include 'EchoStdout'.
--   The value type may be either 'String', or either lazy or strict 'ByteString'.
newtype Stdout a = Stdout {fromStdout :: a}

-- | Collect the @stderr@ of the process.
--   If used, the @stderr@ will not be echoed to the terminal, unless you include 'EchoStderr'.
--   The value type may be either 'String', or either lazy or strict 'ByteString'.
newtype Stderr a = Stderr {fromStderr :: a}

-- | Collect the @stdout@ and @stderr@ of the process.
--   If used, the @stderr@ and @stdout@ will not be echoed to the terminal, unless you include 'EchoStdout' and 'EchoStderr'.
--   The value type may be either 'String', or either lazy or strict 'ByteString'.
newtype Stdouterr a = Stdouterr {fromStdouterr :: a}

-- | Collect the 'ExitCode' of the process.
--   If you do not collect the exit code, any 'ExitFailure' will cause an exception.
newtype Exit = Exit {fromExit :: ExitCode}

-- | Collect the time taken to execute the process. Can be used in conjunction with 'CmdLine' to
--   write helper functions that print out the time of a result.
--
-- @
--timer :: ('CmdResult' r, MonadIO m) => (forall r . 'CmdResult' r => m r) -> m r
--timer act = do
--    ('CmdTime' t, 'CmdLine' x, r) <- act
--    liftIO $ putStrLn $ \"Command \" ++ x ++ \" took \" ++ show t ++ \" seconds\"
--    return r
--
--run :: IO ()
--run = timer $ 'cmd' \"ghc --version\"
-- @
newtype CmdTime = CmdTime {fromCmdTime :: Double}

-- | Collect the command line used for the process. This command line will be approximate -
--   suitable for user diagnostics, but not for direct execution.
newtype CmdLine = CmdLine {fromCmdLine :: String}

class CmdString a where cmdString :: (Str, Str -> a)
instance CmdString () where cmdString = (Unit, \Unit -> ())
instance CmdString String where cmdString = (Str "", \(Str x) -> x)
instance CmdString BS.ByteString where cmdString = (BS BS.empty, \(BS x) -> x)
instance CmdString LBS.ByteString where cmdString = (LBS LBS.empty, \(LBS x) -> x)

-- | A class for specifying what results you want to collect from a process.
--   Values are formed of 'Stdout', 'Stderr', 'Exit' and tuples of those.
class CmdResult a where
    -- Return a list of results (with the right type but dummy data)
    -- and a function to transform a populated set of results into a value
    cmdResult :: ([Result], [Result] -> a)

instance CmdResult Exit where
    cmdResult = ([ResultCode ExitSuccess], \[ResultCode x] -> Exit x)

instance CmdResult ExitCode where
    cmdResult = ([ResultCode ExitSuccess], \[ResultCode x] -> x)

instance CmdResult CmdLine where
    cmdResult = ([ResultLine ""], \[ResultLine x] -> CmdLine x)

instance CmdResult CmdTime where
    cmdResult = ([ResultTime 0], \[ResultTime x] -> CmdTime x)

instance CmdString a => CmdResult (Stdout a) where
    cmdResult = let (a,b) = cmdString in ([ResultStdout a], \[ResultStdout x] -> Stdout $ b x)

instance CmdString a => CmdResult (Stderr a) where
    cmdResult = let (a,b) = cmdString in ([ResultStderr a], \[ResultStderr x] -> Stderr $ b x)

instance CmdString a => CmdResult (Stdouterr a) where
    cmdResult = let (a,b) = cmdString in ([ResultStdouterr a], \[ResultStdouterr x] -> Stdouterr $ b x)

instance CmdResult () where
    cmdResult = ([], \[] -> ())

instance (CmdResult x1, CmdResult x2) => CmdResult (x1,x2) where
    cmdResult = (a1++a2, \rs -> let (r1,r2) = splitAt (length a1) rs in (b1 r1, b2 r2))
        where (a1,b1) = cmdResult
              (a2,b2) = cmdResult

cmdResultWith f = second (f .) cmdResult

instance (CmdResult x1, CmdResult x2, CmdResult x3) => CmdResult (x1,x2,x3) where
    cmdResult = cmdResultWith $ \(a,(b,c)) -> (a,b,c)

instance (CmdResult x1, CmdResult x2, CmdResult x3, CmdResult x4) => CmdResult (x1,x2,x3,x4) where
    cmdResult = cmdResultWith $ \(a,(b,c,d)) -> (a,b,c,d)

instance (CmdResult x1, CmdResult x2, CmdResult x3, CmdResult x4, CmdResult x5) => CmdResult (x1,x2,x3,x4,x5) where
    cmdResult = cmdResultWith $ \(a,(b,c,d,e)) -> (a,b,c,d,e)


-- | Execute a system command. Before running 'command' make sure you 'Development.Shake.need' any files
--   that are used by the command.
--
--   This function takes a list of options (often just @[]@, see 'CmdOption' for the available
--   options), the name of the executable (either a full name, or a program on the @$PATH@) and
--   a list of arguments. The result is often @()@, but can be a tuple containg any of 'Stdout',
--   'Stderr' and 'Exit'. Some examples:
--
-- @
-- 'command_' [] \"gcc\" [\"-c\",\"myfile.c\"]                          -- compile a file, throwing an exception on failure
-- 'Exit' c <- 'command' [] \"gcc\" [\"-c\",myfile]                     -- run a command, recording the exit code
-- ('Exit' c, 'Stderr' err) <- 'command' [] \"gcc\" [\"-c\",\"myfile.c\"]   -- run a command, recording the exit code and error output
-- 'Stdout' out <- 'command' [] \"gcc\" [\"-MM\",\"myfile.c\"]            -- run a command, recording the output
-- 'command_' ['Cwd' \"generated\"] \"gcc\" [\"-c\",myfile]               -- run a command in a directory
-- @
--
--   Unless you retrieve the 'ExitCode' using 'Exit', any 'ExitFailure' will throw an error, including
--   the 'Stderr' in the exception message. If you capture the 'Stdout' or 'Stderr', that stream will not be echoed to the console,
--   unless you use the option 'EchoStdout' or 'EchoStderr'.
--
--   If you use 'command' inside a @do@ block and do not use the result, you may get a compile-time error about being
--   unable to deduce 'CmdResult'. To avoid this error, use 'command_'.
command :: CmdResult r => [CmdOption] -> String -> [String] -> Action r
command opts x xs = fmap b $ commandExplicit "command" opts a x xs
    where (a,b) = cmdResult

-- | A version of 'command' where you do not require any results, used to avoid errors about being unable
--   to deduce 'CmdResult'.
command_ :: [CmdOption] -> String -> [String] -> Action ()
command_ opts x xs = void $ commandExplicit "command_" opts [] x xs


---------------------------------------------------------------------
-- VARIABLE ARGUMENT WRAPPER

type a :-> t = a


-- | Execute a system command. Before running 'cmd' make sure you 'Development.Shake.need' any files
--   that are used by the command.
--
-- * @String@ arguments are treated as whitespace separated arguments.
--
-- * @[String]@ arguments are treated as literal arguments.
--
-- * 'CmdOption' arguments are used as options.
--
--   To take the examples from 'command':
--
-- @
-- () <- 'cmd' \"gcc -c myfile.c\"                                  -- compile a file, throwing an exception on failure
-- 'unit' $ 'cmd' \"gcc -c myfile.c\"                                 -- alternative to () <- binding.
-- 'Exit' c <- 'cmd' \"gcc -c\" [myfile]                              -- run a command, recording the exit code
-- ('Exit' c, 'Stderr' err) <- 'cmd' \"gcc -c myfile.c\"                -- run a command, recording the exit code and error output
-- 'Stdout' out <- 'cmd' \"gcc -MM myfile.c\"                         -- run a command, recording the output
-- 'cmd' ('Cwd' \"generated\") \"gcc -c\" [myfile] :: 'Action' ()         -- run a command in a directory
-- @
--
--   When passing file arguments we use @[myfile]@ so that if the @myfile@ variable contains spaces they are properly escaped.
--
--   If you use 'cmd' inside a @do@ block and do not use the result, you may get a compile-time error about being
--   unable to deduce 'CmdResult'. To avoid this error, bind the result to @()@, or include a type signature, or use
--   the 'unit' function.
--
--   The 'cmd' command can also be run in the 'IO' monad, but then 'Traced' is ignored and command lines are not echoed.
cmd :: CmdArguments args => args :-> Action r
cmd = cmdArguments []

class CmdArguments t where cmdArguments :: [Either CmdOption String] -> t
instance (Arg a, CmdArguments r) => CmdArguments (a -> r) where
    cmdArguments xs x = cmdArguments $ xs ++ arg x
instance CmdResult r => CmdArguments (Action r) where
    cmdArguments x = case partitionEithers x of
        (opts, x:xs) -> let (a,b) = cmdResult in fmap b $ commandExplicit "cmd" opts a x xs
        _ -> error "Error, no executable or arguments given to Development.Shake.cmd"
instance CmdResult r => CmdArguments (IO r) where
    cmdArguments x = case partitionEithers x of
        (opts, x:xs) -> let (a,b) = cmdResult in fmap b $ commandExplicitIO "cmd" opts a x xs
        _ -> error "Error, no executable or arguments given to Development.Shake.cmd"

class Arg a where arg :: a -> [Either CmdOption String]
instance Arg String where arg = map Right . words
instance Arg [String] where arg = map Right
instance Arg CmdOption where arg = return . Left
instance Arg [CmdOption] where arg = map Left
instance Arg a => Arg (Maybe a) where arg = maybe [] arg
