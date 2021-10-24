module Tweetogram.Query.Likes () where

import Conduit (foldlC, mapMC)
import Control.Exception (throwIO, try)
import Data.Aeson (eitherDecodeStrict')
import Data.Conduit (
  ConduitT,
  runConduitRes,
  (.|),
 )
import Data.Conduit.Combinators (
  sourceFile,
  splitOnUnboundedE,
 )
import Data.Default (def)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Time.Clock (UTCTime)
import GHC.IO.Exception (IOErrorType (..), IOException (..))
import Relude
import System.FilePath ((</>))
import Text.Layout.Table (asciiS, rowG, tableString, titlesH)
import Web.Twitter.Types (Status (..), User (..))

data QueryLikesOptions = QueryLikesOptions
  { dataDir :: FilePath
  , topN :: Maybe Int
  , minLikes :: Maybe Int
  }

newtype ParseException = ParseException
  { errorMessage :: String
  }
  deriving (Show)

instance Exception ParseException where
  displayException (ParseException msg) = "could not parse Tweetogram data directory: " <> msg

type UserID = Integer

type TweetID = Integer

data LikesResult = LikesResult
  { users :: Map UserID LikedUser
  , tweets :: Map TweetID LikedTweet
  , groupedLikes :: Map UserID (Set TweetID)
  }
  deriving (Show)

-- TODO: Is being followed by target user?
--
-- NB: I can't use the "following" field for this, since that tells me whether
-- the _API user_ is following the author. Instead, I need to query
-- `GET friends/ids` and cross-reference against the author's user ID.

data LikedUser = LikedUser
  { userID :: Integer
  , screenName :: Text
  , displayName :: Text
  , isVerified :: Bool
  , createdAt :: UTCTime
  , followerCount :: Int
  , followingCount :: Int
  , tweetCount :: Int
  , likesCount :: Int
  }
  deriving (Show)

data LikedTweet = LikedTweet
  { tweetID :: Integer
  , -- Note: even though the official Twitter clients will display some accounts
    -- as "containing potentially sensitive content", this doesn't seem to be an
    -- actual field available on the API for users. Only individual _tweets_
    -- have a "potentially sensitive" field.
    --
    -- I'm not totally sure how the client decides to display this warning. My
    -- guess is that it takes a threshold percentage of potentially sensitive
    -- tweets, since it appears that some accounts that have sensitive tweets
    -- still don't show the warning.
    --
    -- See also:
    -- - v1 API user object model: https://developer.twitter.com/en/docs/twitter-api/v1/data-dictionary/object-model/user
    -- - v2 API user object model: https://developer.twitter.com/en/docs/twitter-api/data-dictionary/object-model/user
    possiblySensitive :: Bool
  }
  deriving (Show)

queryLikes :: QueryLikesOptions -> IO ()
queryLikes QueryLikesOptions{..} = do
  result <-
    try $
      runConduitRes $
        sourceFile (dataDir </> "likes.ndjson")
          .| splitOnUnboundedE (== (toEnum $ ord '\n'))
          .| decodeLikes
          .| groupLikesByAuthor

  case result of
    Left err -> case fromException err of
      Just (IOError _ NoSuchThing _ description _ (Just filename)) ->
        putStrLn $ "Could not load liked tweets from " <> show filename <> ": " <> description
      Just _ -> putStrLn $ "Unexpected error: " <> displayException err
      Nothing -> putStrLn $ "Unexpected error: " <> displayException err
    Right r -> render r
 where
  decodeLikes :: (MonadIO m) => ConduitT ByteString Status m ()
  decodeLikes = mapMC $ \line -> do
    case eitherDecodeStrict' line of
      Left err -> liftIO $ throwIO $ ParseException err
      Right status -> pure status

  groupLikesByAuthor :: (Monad m) => ConduitT Status o m LikesResult
  groupLikesByAuthor = foldlC f zero
   where
    zero =
      LikesResult
        { users = Map.empty
        , tweets = Map.empty
        , groupedLikes = Map.empty
        }

    f :: LikesResult -> Status -> LikesResult
    f LikesResult{..} Status{statusUser = User{..}, ..} =
      LikesResult
        { users = Map.insert userId likedUser users
        , tweets = Map.insert statusId likedTweet tweets
        , groupedLikes = Map.insertWith Set.union userId (Set.singleton statusId) groupedLikes
        }
     where
      likedUser =
        LikedUser
          { userID = userId
          , screenName = userScreenName
          , displayName = userName
          , isVerified = userVerified
          , createdAt = userCreatedAt
          , followerCount = userFollowersCount
          , followingCount = userFriendsCount
          , tweetCount = userStatusesCount
          , likesCount = userFavoritesCount
          }

      -- TODO: I should just roll this directly into the User field instead of
      -- saving a list of all tweets. Use a Users Map update on sensitive
      -- tweets. Add a User field called "has sensitive tweets".
      likedTweet =
        LikedTweet
          { tweetID = statusId
          , possiblySensitive = Just True == statusPossiblySensitive
          }

  render :: LikesResult -> IO ()
  render LikesResult{..} =
    putStrLn $
      tableString
        (fmap (const def) headers)
        asciiS
        (titlesH headers)
        $ fmap rowG rows
   where
    ordered :: [(LikedUser, Set TweetID)]
    ordered =
      sortOn (Down . Set.size . snd) $
        sortOn (screenName . fst) $
          first getUser <$> Map.toList groupedLikes

    getUser :: UserID -> LikedUser
    getUser userID = case Map.lookup userID users of
      Just lu -> lu
      Nothing -> error $ "impossible: inconsistent Tweetogram data: unknown user ID: " <> show userID

    filtered :: [(LikedUser, Set TweetID)]
    filtered = filterTopN $ filterMinLikes ordered
     where
      filterMinLikes :: [(LikedUser, Set TweetID)] -> [(LikedUser, Set TweetID)]
      filterMinLikes = case minLikes of
        Just n -> filter ((>= n) . Set.size . snd)
        Nothing -> id

      filterTopN :: [(LikedUser, Set TweetID)] -> [(LikedUser, Set TweetID)]
      filterTopN = maybe id take topN

    hydrated :: [(LikedUser, [LikedTweet])]
    hydrated = second (fmap getTweet . toList) <$> filtered

    getTweet :: TweetID -> LikedTweet
    getTweet tweetID = case Map.lookup tweetID tweets of
      Just lt -> lt
      Nothing -> error $ "impossible: inconsistent Tweetogram data: unknown tweet ID: " <> show tweetID

    headers :: [String]
    headers =
      [ "Rank"
      , "Liked tweets"
      , "Handle"
      , "Name"
      , "Verified?"
      , "NSFW*?"
      , "Followers"
      , "Following"
      , "Tweets"
      , "Likes"
      , "Created"
      ]

    rows :: [[String]]
    rows = f <$> zip [0 ..] hydrated
     where
      f :: (Integer, (LikedUser, [LikedTweet])) -> [String]
      f (i, (LikedUser{..}, likes)) =
        [ show (i + 1)
        , show (length likes)
        , toString screenName
        , toString displayName
        , show isVerified
        , show (any possiblySensitive likes)
        , show followerCount
        , show followingCount
        , show tweetCount
        , show likesCount
        , show createdAt
        ]
