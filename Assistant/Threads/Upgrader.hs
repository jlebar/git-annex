{- git-annex assistant thread to detect when upgrade is needed
 -
 - Copyright 2013 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

{-# LANGUAGE CPP #-}

module Assistant.Threads.Upgrader (
	upgraderThread
) where

import Assistant.Common
import Assistant.Types.UrlRenderer
import Assistant.DaemonStatus
import Assistant.Alert
import Utility.NotificationBroadcaster
import Utility.Tmp
import qualified Build.SysConfig
import qualified Utility.Url as Url
import qualified Annex.Url as Url
import qualified Git.Version
import Types.Distribution
#ifdef WITH_WEBAPP
import Assistant.WebApp.Types
#endif

import Data.Time.Clock
import qualified Data.Text as T

upgraderThread :: UrlRenderer -> NamedThread
upgraderThread urlrenderer = namedThread "Upgrader" $ do
	checkUpgrade urlrenderer -- TODO: remove
	when (isJust Build.SysConfig.upgradelocation) $ do
		h <- liftIO . newNotificationHandle False . networkConnectedNotifier =<< getDaemonStatus
		go h Nothing
  where
  	{- Wait for a network connection event. Then see if it's been
	 - half a day since the last upgrade check. If so, proceed with
	 - check. -}
	go h lastchecked = do
		liftIO $ waitNotification h
		now <- liftIO getCurrentTime
		if maybe True (\t -> diffUTCTime now t > halfday) lastchecked
			then do
				checkUpgrade urlrenderer
				go h =<< Just <$> liftIO getCurrentTime
			else go h lastchecked
	halfday = 12 * 60 * 60

checkUpgrade :: UrlRenderer -> Assistant ()
checkUpgrade urlrenderer = do
	debug [ "Checking if an upgrade is available." ]
	go =<< getDistributionInfo
  where
	go Nothing = debug [ "Failed to check if upgrade is available." ]
	go (Just d) = do
		let installed = Git.Version.normalize Build.SysConfig.packageversion
		let avail = Git.Version.normalize $ distributionVersion d
		let old = Git.Version.normalize <$> distributionUrgentUpgrade d
		if Just installed <= old
			then canUpgrade Low urlrenderer d
			else when (installed < avail) $
				canUpgrade High urlrenderer d

canUpgrade :: AlertPriority -> UrlRenderer -> GitAnnexDistribution -> Assistant ()
canUpgrade urgency urlrenderer d = do
#ifdef WITH_WEBAPP
	button <- mkAlertButton False (T.pack "Upgrade") urlrenderer (ConfigUpgradeR d)
	void $ addAlert (canUpgradeAlert urgency button)
#else
	noop
#endif

getDistributionInfo :: Assistant (Maybe GitAnnexDistribution)
getDistributionInfo = do
	ua <- liftAnnex Url.getUserAgent
	liftIO $ withTmpFile "git-annex.tmp" $ \tmpfile h -> do
		hClose h
		ifM (Url.downloadQuiet distributionInfoUrl [] [] tmpfile ua)
			( readish <$> readFileStrict tmpfile
			, return Nothing
			)

distributionInfoUrl :: String
distributionInfoUrl = fromJust Build.SysConfig.upgradelocation ++ "/info"