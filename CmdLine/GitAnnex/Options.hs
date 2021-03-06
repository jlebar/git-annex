{- git-annex options
 -
 - Copyright 2010-2015 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module CmdLine.GitAnnex.Options where

import System.Console.GetOpt

import Common.Annex
import qualified Git.Config
import Git.Types
import Types.TrustLevel
import Types.NumCopies
import Types.Messages
import qualified Annex
import qualified Remote
import qualified Limit
import qualified Limit.Wanted
import CmdLine.Option
import CmdLine.Usage

-- Options that are accepted by all git-annex sub-commands,
-- although not always used.
gitAnnexOptions :: [Option]
gitAnnexOptions = commonOptions ++
	[ Option ['N'] ["numcopies"] (ReqArg setnumcopies paramNumber)
		"override default number of copies"
	, Option [] ["trust"] (trustArg Trusted)
		"override trust setting"
	, Option [] ["semitrust"] (trustArg SemiTrusted)
		"override trust setting back to default"
	, Option [] ["untrust"] (trustArg UnTrusted)
		"override trust setting to untrusted"
	, Option ['c'] ["config"] (ReqArg setgitconfig "NAME=VALUE")
		"override git configuration setting"
	, Option [] ["user-agent"] (ReqArg setuseragent paramName)
		"override default User-Agent"
	, Option [] ["trust-glacier"] (NoArg (Annex.setFlag "trustglacier"))
		"Trust Amazon Glacier inventory"
	]
  where
	trustArg t = ReqArg (Remote.forceTrust t) paramRemote
	setnumcopies v = maybe noop
		(\n -> Annex.changeState $ \s -> s { Annex.forcenumcopies = Just $ NumCopies n })
		(readish v)
	setuseragent v = Annex.changeState $ \s -> s { Annex.useragent = Just v }
	setgitconfig v = inRepo (Git.Config.store v)
		>>= pure . (\r -> r { gitGlobalOpts = gitGlobalOpts r ++ [Param "-c", Param v] })
		>>= Annex.changeGitRepo

-- Options for matching on annexed keys, rather than work tree files.
keyOptions :: [Option]
keyOptions = 
	[ Option ['A'] ["all"] (NoArg (Annex.setFlag "all"))
		"operate on all versions of all files"
	, Option ['U'] ["unused"] (NoArg (Annex.setFlag "unused"))
		"operate on files found by last run of git-annex unused"
	, Option [] ["key"] (ReqArg (Annex.setField "key") paramKey)
		"operate on specified key"
	]

-- Options to match properties of annexed files.
annexedMatchingOptions :: [Option]
annexedMatchingOptions = concat
	[ nonWorkTreeMatchingOptions'
	, fileMatchingOptions'
	, combiningOptions
	, [timeLimitOption]
	]

-- Matching options that don't need to examine work tree files.
nonWorkTreeMatchingOptions :: [Option]
nonWorkTreeMatchingOptions = nonWorkTreeMatchingOptions' ++ combiningOptions

nonWorkTreeMatchingOptions' :: [Option]
nonWorkTreeMatchingOptions' = 
	[ Option ['i'] ["in"] (ReqArg Limit.addIn paramRemote)
		"match files present in a remote"
	, Option ['C'] ["copies"] (ReqArg Limit.addCopies paramNumber)
		"skip files with fewer copies"
	, Option [] ["lackingcopies"] (ReqArg (Limit.addLackingCopies False) paramNumber)
		"match files that need more copies"
	, Option [] ["approxlackingcopies"] (ReqArg (Limit.addLackingCopies True) paramNumber)
		"match files that need more copies (faster)"
	, Option ['B'] ["inbackend"] (ReqArg Limit.addInBackend paramName)
		"match files using a key-value backend"
	, Option [] ["inallgroup"] (ReqArg Limit.addInAllGroup paramGroup)
		"match files present in all remotes in a group"
	, Option [] ["metadata"] (ReqArg Limit.addMetaData "FIELD=VALUE")
		"match files with attached metadata"
	, Option [] ["want-get"] (NoArg Limit.Wanted.addWantGet)
		"match files the repository wants to get"
	, Option [] ["want-drop"] (NoArg Limit.Wanted.addWantDrop)
		"match files the repository wants to drop"
	]

-- Options to match files which may not yet be annexed.
fileMatchingOptions :: [Option]
fileMatchingOptions = fileMatchingOptions' ++ combiningOptions

fileMatchingOptions' :: [Option]
fileMatchingOptions' =
	[ Option ['x'] ["exclude"] (ReqArg Limit.addExclude paramGlob)
		"skip files matching the glob pattern"
	, Option ['I'] ["include"] (ReqArg Limit.addInclude paramGlob)
		"limit to files matching the glob pattern"
	, Option [] ["largerthan"] (ReqArg Limit.addLargerThan paramSize)
		"match files larger than a size"
	, Option [] ["smallerthan"] (ReqArg Limit.addSmallerThan paramSize)
		"match files smaller than a size"
	]

combiningOptions :: [Option]
combiningOptions =
	[ longopt "not" "negate next option"
	, longopt "and" "both previous and next option must match"
	, longopt "or" "either previous or next option must match"
	, shortopt "(" "open group of options"
	, shortopt ")" "close group of options"
	]
  where
	longopt o = Option [] [o] $ NoArg $ Limit.addToken o
	shortopt o = Option o [] $ NoArg $ Limit.addToken o

fromOption :: Option
fromOption = fieldOption ['f'] "from" paramRemote "source remote"

toOption :: Option
toOption = fieldOption ['t'] "to" paramRemote "destination remote"

fromToOptions :: [Option]
fromToOptions = [fromOption, toOption]

jsonOption :: Option
jsonOption = Option ['j'] ["json"] (NoArg (Annex.setOutput JSONOutput))
	"enable JSON output"

timeLimitOption :: Option
timeLimitOption = Option ['T'] ["time-limit"]
	(ReqArg Limit.addTimeLimit paramTime)
	"stop after the specified amount of time"
