{-# LANGUAGE CPP #-}
{-# LANGUAGE BangPatterns #-}

{- git-annex watch daemon
 -
 - Copyright 2012 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -
 - Overview of threads and MVars, etc:
 -
 - Thread 1: parent
 - 	The initial thread run, double forks to background, starts other
 - 	threads, and then stops, waiting for them to terminate,
 - 	or for a ctrl-c.
 - Thread 2: inotify
 - 	Notices new files, and calls handlers for events, queuing changes.
 - Thread 3: inotify internal
 - 	Used by haskell inotify library to ensure inotify event buffer is
 - 	kept drained.
 - Thread 4: inotify initial scan
 -	A MVar lock is used to prevent other inotify handlers from running
 -	until this is complete.
 - Thread 5: committer
 - 	Waits for changes to occur, and runs the git queue to update its
 - 	index, then commits.
 - Thread 6: status logger
 - 	Wakes up periodically and records the daemon's status to disk.
 -
 - State MVar:
 - 	The Annex state is stored here, which allows resuscitating the
 - 	Annex monad in IO actions run by the inotify and committer
 - 	threads. Thus, a single state is shared amoung the threads, and
 - 	only one at a time can access it.
 - DaemonStatus MVar:
 - 	The daemon's current status. This MVar should only be manipulated
 - 	from inside the Annex monad, which ensures it's accessed only
 - 	after the State MVar.
 - ChangeChan STM TChan:
 - 	Changes are indicated by writing to this channel. The committer
 - 	reads from it.
 -}

module Command.Watch where

import Common.Annex
import Command
import Utility.Daemon
import Utility.LogFile
import Utility.ThreadLock
import qualified Annex
import qualified Annex.Queue
import qualified Command.Add
import qualified Git.Command
import qualified Git.UpdateIndex
import qualified Git.HashObject
import qualified Git.LsFiles
import qualified Backend
import Annex.Content
import Annex.CatFile
import Git.Types
import Option

import Control.Concurrent
import Control.Concurrent.STM
import Data.Time.Clock
import Data.Bits.Utils
import System.Posix.Types
import qualified Data.ByteString.Lazy as L

#if defined linux_HOST_OS
import Utility.Inotify
import System.INotify
#endif

data DaemonStatus = DaemonStatus
	-- False when the daemon is performing its startup scan
	{ scanComplete :: Bool
	-- Time when a previous process of the daemon was running ok
	, lastRunning :: Maybe EpochTime
	}

newDaemonStatus :: Annex DaemonStatus
newDaemonStatus = return $ DaemonStatus
	{ scanComplete = False
	, lastRunning = Nothing
	}

getDaemonStatus :: MVar DaemonStatus -> Annex DaemonStatus
getDaemonStatus = liftIO . readMVar

modifyDaemonStatus :: MVar DaemonStatus -> (DaemonStatus -> DaemonStatus) -> Annex ()
modifyDaemonStatus status a = liftIO $ modifyMVar_ status (return . a)

type ChangeChan = TChan Change

type Handler = FilePath -> Maybe FileStatus -> MVar DaemonStatus -> Annex (Maybe Change)

data Change = Change
	{ changeTime :: UTCTime
	, changeFile :: FilePath
	, changeDesc :: String
	}
	deriving (Show)

def :: [Command]
def = [withOptions [foregroundOption, stopOption] $ 
	command "watch" paramNothing seek "watch for changes"]

seek :: [CommandSeek]
seek = [withFlag stopOption $ \stopdaemon -> 
	withFlag foregroundOption $ \foreground ->
	withNothing $ start foreground stopdaemon]

foregroundOption :: Option
foregroundOption = Option.flag [] "foreground" "do not daemonize"

stopOption :: Option
stopOption = Option.flag [] "stop" "stop daemon"

start :: Bool -> Bool -> CommandStart
start foreground stopdaemon = notBareRepo $ do
	if stopdaemon
		then liftIO . stopDaemon =<< fromRepo gitAnnexPidFile
		else withStateMVar $ startDaemon foreground
	stop

startDaemon :: Bool -> MVar Annex.AnnexState -> Annex ()
startDaemon foreground st
	| foreground = do
		showStart "watch" "."
		go id
	| otherwise = do
		logfd <- liftIO . openLog =<< fromRepo gitAnnexLogFile
		pidfile <- fromRepo gitAnnexPidFile
		go $ daemonize logfd (Just pidfile) False
	where
		go a = do
			daemonstatus <- newDaemonStatus
			liftIO $ a $ do
				dstatus <- newMVar daemonstatus
				changechan <- runChangeChan newTChan
				watch st dstatus changechan

watch :: MVar Annex.AnnexState -> MVar DaemonStatus -> ChangeChan -> IO ()
#if defined linux_HOST_OS
watch st dstatus changechan = withINotify $ \i -> do
	-- The commit thread is started early, so that the user
	-- can immediately begin adding files and having them
	-- committed, even while the startup scan is taking place.
	_ <- forkIO $ commitThread st changechan
	runStateMVar st $
		showAction "scanning"
	-- This does not return until the startup scan is done.
	-- That can take some time for large trees.
	watchDir i "." (ignored . takeFileName) hooks
	runStateMVar st $
		modifyDaemonStatus dstatus $ \s -> s { scanComplete = True }
	-- Notice any files that were deleted before inotify
	-- was started.
	runStateMVar st $ do
		inRepo $ Git.Command.run "add" [Param "--update"]
		showAction "started"
	waitForTermination
	where
		hook a = Just $ runHandler st dstatus changechan a
		hooks = WatchHooks
			{ addHook = hook onAdd
			, delHook = hook onDel
			, addSymlinkHook = hook onAddSymlink
			, delDirHook = hook onDelDir
			, errHook = hook onErr
			}
#else
watch = error "watch mode is so far only available on Linux"
#endif

ignored :: FilePath -> Bool
ignored ".git" = True
ignored ".gitignore" = True
ignored ".gitattributes" = True
ignored _ = False

{- Stores the Annex state in a MVar, so that threaded actions can access
 - it.
 -
 - Once the action is finished, retrieves the state from the MVar.
 -}
withStateMVar :: (MVar Annex.AnnexState -> Annex a) -> Annex a
withStateMVar a = do
	state <- Annex.getState id
	mvar <- liftIO $ newMVar state
	r <- a mvar
	newstate <- liftIO $ takeMVar mvar
	Annex.changeState (const newstate)
	return r

{- Runs an Annex action, using the state from the MVar. -}
runStateMVar :: MVar Annex.AnnexState -> Annex a -> IO a
runStateMVar mvar a = do
	startstate <- takeMVar mvar
	!(r, newstate) <- Annex.run startstate a
	putMVar mvar newstate
	return r

runChangeChan :: STM a -> IO a
runChangeChan = atomically

{- Runs an action handler, inside the Annex monad, and if there was a
 - change, adds it to the ChangeChan.
 -
 - Exceptions are ignored, otherwise a whole watcher thread could be crashed.
 -}
runHandler :: MVar Annex.AnnexState -> MVar DaemonStatus -> ChangeChan -> Handler -> FilePath -> Maybe FileStatus -> IO ()
runHandler st dstatus changechan handler file filestatus = void $ do
	r <- tryIO go
	case r of
		Left e -> print e
		Right Nothing -> noop
		Right (Just change) -> void $
			runChangeChan $ writeTChan changechan change
	where
		go = runStateMVar st $ handler file filestatus dstatus

{- Handlers call this when they made a change that needs to get committed. -}
madeChange :: FilePath -> String -> Annex (Maybe Change)
madeChange file desc = do
	-- Just in case the commit thread is not flushing the queue fast enough.
	Annex.Queue.flushWhenFull
	liftIO $ Just <$> (Change <$> getCurrentTime <*> pure file <*> pure desc)

noChange :: Annex (Maybe Change)
noChange = return Nothing

{- Adding a file is tricky; the file has to be replaced with a symlink
 - but this is race prone, as the symlink could be changed immediately
 - after creation. To avoid that race, git add is not used to stage the
 - symlink.
 -
 - Inotify will notice the new symlink, so this Handler does not stage it
 - or return a Change, leaving that to onAddSymlink.
 -
 - During initial directory scan, this will be run for any files that
 - are already checked into git. We don't want to turn those into symlinks,
 - so do a check. This is rather expensive, but only happens during
 - startup.
 -}
onAdd :: Handler
onAdd file _filestatus dstatus = do
	ifM (scanComplete <$> getDaemonStatus dstatus)
		( go
		, ifM (null <$> inRepo (Git.LsFiles.notInRepo False [file]))
			( noChange
			, go
			)
		)
	where
		go = do
			showStart "add" file
			handle =<< Command.Add.ingest file
			noChange
		handle Nothing = showEndFail
		handle (Just key) = do
			Command.Add.link file key True
			showEndOk

{- A symlink might be an arbitrary symlink, which is just added.
 - Or, if it is a git-annex symlink, ensure it points to the content
 - before adding it.
 - 
 -}
onAddSymlink :: Handler
onAddSymlink file filestatus dstatus = go =<< Backend.lookupFile file
	where
		go (Just (key, _)) = do
			link <- calcGitLink file key
			ifM ((==) link <$> liftIO (readSymbolicLink file))
				( ensurestaged link =<< getDaemonStatus dstatus
				, do
					liftIO $ removeFile file
					liftIO $ createSymbolicLink link file
					addlink link
				)
		go Nothing = do -- other symlink
			link <- liftIO (readSymbolicLink file)
			ensurestaged link =<< getDaemonStatus dstatus

		{- This is often called on symlinks that are already
		 - staged correctly. A symlink may have been deleted
		 - and being re-added, or added when the watcher was
		 - not running. So they're normally restaged to make sure.
		 -
		 - As an optimisation, during the status scan, avoid
		 - restaging everything. Only links that were created since
		 - the last time the daemon was running are staged.
		 - (If the daemon has never ran before, avoid staging
		 - links too.)
		 -}
		ensurestaged link daemonstatus
			| scanComplete daemonstatus = addlink link
			| otherwise = case filestatus of
				Just s
					| safe (statusChangeTime s) -> noChange
				_ -> addlink link
			where
				safe t = maybe True (> t) (lastRunning daemonstatus)

		{- For speed, tries to reuse the existing blob for
		 - the symlink target. -}
		addlink link = do
			v <- catObjectDetails $ Ref $ ':':file
			case v of
				Just (currlink, sha)
					| s2w8 link == L.unpack currlink ->
						stageSymlink file sha
				_ -> do
					sha <- inRepo $
						Git.HashObject.hashObject BlobObject link
					stageSymlink file sha
			madeChange file "link"

onDel :: Handler
onDel file _ _dstatus = do
	Annex.Queue.addUpdateIndex =<<
		inRepo (Git.UpdateIndex.unstageFile file)
	madeChange file "rm"

{- A directory has been deleted, or moved, so tell git to remove anything
 - that was inside it from its cache. Since it could reappear at any time,
 - use --cached to only delete it from the index. 
 -
 - Note: This could use unstageFile, but would need to run another git
 - command to get the recursive list of files in the directory, so rm is
 - just as good. -}
onDelDir :: Handler
onDelDir dir _ _dstatus = do
	Annex.Queue.addCommand "rm"
		[Params "--quiet -r --cached --ignore-unmatch --"] [dir]
	madeChange dir "rmdir"

{- Called when there's an error with inotify. -}
onErr :: Handler
onErr msg _ _dstatus = do
	warning msg
	return Nothing

{- Adds a symlink to the index, without ever accessing the actual symlink
 - on disk. -}
stageSymlink :: FilePath -> Sha -> Annex ()
stageSymlink file sha =
	Annex.Queue.addUpdateIndex =<<
		inRepo (Git.UpdateIndex.stageSymlink file sha)

{- Gets all unhandled changes.
 - Blocks until at least one change is made. -}
getChanges :: ChangeChan -> IO [Change]
getChanges chan = runChangeChan $ do
	c <- readTChan chan
	go [c]
	where
		go l = do
			v <- tryReadTChan chan
			case v of
				Nothing -> return l
				Just c -> go (c:l)

{- Puts unhandled changes back into the channel.
 - Note: Original order is not preserved. -}
refillChanges :: ChangeChan -> [Change] -> IO ()
refillChanges chan cs = runChangeChan $ mapM_ (writeTChan chan) cs

{- This thread makes git commits at appropriate times. -}
commitThread :: MVar Annex.AnnexState -> ChangeChan -> IO ()
commitThread st changechan = forever $ do
	-- First, a simple rate limiter.
	threadDelay oneSecond
	-- Next, wait until at least one change has been made.
	cs <- getChanges changechan
	-- Now see if now's a good time to commit.
	time <- getCurrentTime
	if shouldCommit time cs
		then void $ tryIO $ runStateMVar st commitStaged
		else refillChanges changechan cs
	where
		oneSecond = 1000000 -- microseconds

commitStaged :: Annex ()
commitStaged = do
	Annex.Queue.flush
	inRepo $ Git.Command.run "commit"
		[ Param "--allow-empty-message"
		, Param "-m", Param ""
		-- Empty commits may be made if tree changes cancel
		-- each other out, etc
		, Param "--allow-empty"
		-- Avoid running the usual git-annex pre-commit hook;
		-- watch does the same symlink fixing, and we don't want
		-- to deal with unlocked files in these commits.
		, Param "--quiet"
		]

{- Decide if now is a good time to make a commit.
 - Note that the list of change times has an undefined order.
 -
 - Current strategy: If there have been 10 commits within the past second,
 - a batch activity is taking place, so wait for later.
 -}
shouldCommit :: UTCTime -> [Change] -> Bool
shouldCommit now changes
	| len == 0 = False
	| len > 10000 = True -- avoid bloating queue too much
	| length (filter thisSecond changes) < 10 = True
	| otherwise = False -- batch activity
	where
		len = length changes
		thisSecond c = now `diffUTCTime` changeTime c <= 1
