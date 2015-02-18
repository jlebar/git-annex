{- Persistent sqlite database handles.
 -
 - Copyright 2015 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

{-# LANGUAGE BangPatterns #-}

module Database.Handle (
	DbHandle,
	initDb,
	openDb,
	queryDb,
	closeDb,
	Size,
	queueDb,
	flushQueueDb,
	commitDb,
) where

import Utility.Exception
import Messages

import Database.Persist.Sqlite
import qualified Database.Sqlite as Sqlite
import Control.Monad
import Control.Monad.IO.Class (liftIO)
import Control.Concurrent
import Control.Concurrent.Async
import Control.Exception (throwIO)
import qualified Data.Text as T

{- A DbHandle is a reference to a worker thread that communicates with
 - the database. It has a MVar which Jobs are submitted to. -}
data DbHandle = DbHandle (Async ()) (MVar Job) (MVar DbQueue)

{- Ensures that the database is initialized. Pass the migration action for
 - the database.
 -
 - The database is put into WAL mode, to prevent readers from blocking
 - writers, and prevent a writer from blocking readers.
 -}
initDb :: FilePath -> SqlPersistM () -> IO DbHandle
initDb db migration = do
	enableWAL db
	h <- openDb db
	either throwIO (const $ return ()) =<< commitDb h migration
	return h
	
enableWAL :: FilePath -> IO ()
enableWAL db = do
	conn <- Sqlite.open (T.pack db)
	stmt <- Sqlite.prepare conn (T.pack "PRAGMA journal_mode=WAL;")
	void $ Sqlite.step stmt
	void $ Sqlite.finalize stmt
	Sqlite.close conn

{- Opens the database, but does not perform any migrations. Only use
 - if the database is known to exist and have the right tables. -}
openDb :: FilePath -> IO DbHandle
openDb db = do
	jobs <- newEmptyMVar
	worker <- async (workerThread (T.pack db) jobs)
	q <- newMVar emptyDbQueue
	return $ DbHandle worker jobs q

data Job
	= QueryJob (SqlPersistM ())
	| ChangeJob ((SqlPersistM () -> IO ()) -> IO ())
	| CloseJob

workerThread :: T.Text -> MVar Job -> IO ()
workerThread db jobs = catchNonAsync loop showerr
  where
  	showerr e = liftIO $ warningIO $
		"sqlite worker thread crashed: " ++ show e
	run = runSqlite db
	loop = do
		r <- run queryloop
		case r of
			QueryJob _ -> loop
			-- change is run in a separate database connection
			-- since sqlite only supports a single writer at a
			-- time, and it may crash the database connection
			ChangeJob a -> a run >> loop
			CloseJob -> return ()
	queryloop = do
		job <- liftIO $ takeMVar jobs
		case job of
			QueryJob a -> a >> queryloop
			_ -> return job

{- Makes a query using the DbHandle. This should not be used to make
 - changes to the database!
 -
 - Note that the action is not run by the calling thread, but by a
 - worker thread. Exceptions are propigated to the calling thread.
 -
 - Only one action can be run at a time against a given DbHandle.
 - If called concurrently in the same process, this will block until
 - it is able to run.
 -
 - Warning: Under heavy traffic, this can fail with an exception
 - that contains "ErrorBusy". WAL mode does not entirely prevent this.
 - The fallback value is returned in this case.
 -}
queryDb :: DbHandle -> a -> SqlPersistM a -> IO a
queryDb (DbHandle _ jobs _) fallback a =
	catchNonAsync go (\_ -> return fallback )
  where
	go = do
		res <- newEmptyMVar
		putMVar jobs $ QueryJob $
			liftIO . putMVar res =<< tryNonAsync a
		either throwIO return =<< takeMVar res

closeDb :: DbHandle -> IO ()
closeDb h@(DbHandle worker jobs _) = do
	flushQueueDb h
	putMVar jobs CloseJob
	wait worker

type Size = Int

{- A queue of actions to perform, with a count of the number of actions
 - queued. -}
data DbQueue = DbQueue Size (SqlPersistM ())

emptyDbQueue :: DbQueue
emptyDbQueue = DbQueue 0 (return ())

{- Queues a change to be made to the database. It will be buffered
 - to be committed later, unless the queue gets larger than the specified
 - size.
 -
 - (Be sure to call closeDb or flushQueueDb to ensure the change
 - gets committed.)
 -
 - Transactions built up by queueDb are sent to sqlite all at once.
 - If sqlite fails due to another change being made concurrently by another
 - process, the transaction is put back in the queue. This solves
 - the sqlite multiple writer problem.
 -}
queueDb :: DbHandle -> Size -> SqlPersistM () -> IO ()
queueDb h@(DbHandle _ _ qvar) maxsz a = do
	DbQueue sz qa <- takeMVar qvar
	let !sz' = sz + 1
	let qa' = qa >> a
	let enqueue newsz = putMVar qvar (DbQueue newsz qa')
	if sz' > maxsz
		then do
			r <- commitDb h qa'
			case r of
				Left e -> enqueue 0
				Right _ -> putMVar qvar emptyDbQueue
		else enqueue sz'

{- If flushing the queue fails, this could be because there is another
 - writer to the database. Retry repeatedly for up to 10 seconds. -}
flushQueueDb :: DbHandle -> IO ()
flushQueueDb h@(DbHandle _ _ qvar) = do
	DbQueue sz qa <- takeMVar qvar	
	when (sz > 0) $
		robustly Nothing 100 (commitDb h qa)
  where
	robustly :: Maybe SomeException -> Int -> IO (Either SomeException ()) -> IO ()
	robustly e 0 _ = error $ "failed to commit changes to sqlite database: " ++ show e
	robustly _ n a = do
		r <- a
		case r of
			Right _ -> return ()
			Left e -> do
				threadDelay 100000 -- 1/10th second
				robustly (Just e) (n-1) a

commitDb :: DbHandle -> SqlPersistM () -> IO (Either SomeException ())
commitDb (DbHandle _ jobs _) a = do
	res <- newEmptyMVar
	putMVar jobs $ ChangeJob $ \runner ->
		liftIO $ putMVar res =<< tryNonAsync (runner a)
	takeMVar res