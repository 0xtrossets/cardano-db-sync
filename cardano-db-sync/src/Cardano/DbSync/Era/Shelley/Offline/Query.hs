{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Cardano.DbSync.Era.Shelley.Offline.Query
  ( queryOfflinePoolData
  ) where

import           Cardano.Prelude hiding (from, groupBy, on, retry)

import           Cardano.DbSync.Era.Shelley.Offline.FetchQueue (newRetry, retryAgain)

import           Data.Time (UTCTime)
import           Data.Time.Clock.POSIX (POSIXTime)
import qualified Data.Time.Clock.POSIX as Time

import           Cardano.Db
                   (EntityField (PoolHashId, PoolHashView, PoolMetadataRefHash, PoolMetadataRefId, PoolMetadataRefPoolId, PoolMetadataRefUrl, PoolOfflineDataPmrId, PoolOfflineFetchErrorFetchTime, PoolOfflineFetchErrorId, PoolOfflineFetchErrorPmrId, PoolOfflineFetchErrorPoolId, PoolOfflineFetchErrorRetryCount),
                   PoolHash, PoolHashId, PoolMetaHash (PoolMetaHash), PoolMetadataRef,
                   PoolMetadataRefId, PoolOfflineData, PoolOfflineFetchError,
                   PoolOfflineFetchErrorId, PoolUrl (PoolUrl))
import           Cardano.DbSync.Types (PoolFetchRetry (..))

import           Database.Esqueleto.Experimental (SqlBackend, SqlExpr, Value (..), ValueList, desc,
                   from, groupBy, in_, innerJoin, just, max_, notExists, on, orderBy, select,
                   subList_select, table, where_, (:&) ((:&)), (==.), (^.))
import           System.Random.Shuffle (shuffleM)

{- HLINT ignore "Fuse on/on" -}

queryOfflinePoolData :: MonadIO m => POSIXTime -> Int -> ReaderT SqlBackend m [PoolFetchRetry]
queryOfflinePoolData now maxCount = do
  -- Results from the query are shuffles so we don't continuously get the same entries.
  xs <- queryNewPoolFetch now
  if length xs >= maxCount
    then take maxCount <$> liftIO (shuffleM xs)
    else do
      ys <- queryPoolFetchRetry (Time.posixSecondsToUTCTime now)
      take maxCount . (xs ++) <$> liftIO (shuffleM ys)

-- Get pool fetch data for new pools (ie pools that had PoolOfflineData entry and no
-- PoolOfflineFetchError).
queryNewPoolFetch :: MonadIO m => POSIXTime -> ReaderT SqlBackend m [PoolFetchRetry]
queryNewPoolFetch now = do
    res <- select $ do
      (ph :& pmr) <-
        from $ table @PoolHash
        `innerJoin` table @PoolMetadataRef
        `on` (\(ph :& pmr) -> ph ^. PoolHashId ==. pmr ^. PoolMetadataRefPoolId)
      where_ (just (pmr ^. PoolMetadataRefId) `in_` latestRefs)
      where_ (notExists $ from (table @PoolOfflineData) >>= \pod -> where_ (pod ^. PoolOfflineDataPmrId ==. pmr ^. PoolMetadataRefId))
      where_ (notExists $ from (table @PoolOfflineFetchError) >>= \pofe -> where_ (pofe ^. PoolOfflineFetchErrorPmrId ==. pmr ^. PoolMetadataRefId))
      pure
        ( ph ^. PoolHashId
        , pmr ^. PoolMetadataRefId
        , pmr ^. PoolMetadataRefUrl
        , pmr ^. PoolMetadataRefHash
        )
    pure $ map convert res
  where
    -- This assumes that the autogenerated `id` field is a reliable proxy for time, ie, higher
    -- `id` was added later. This is a valid assumption because the primary keys are
    -- monotonically increasing and never reused.
    latestRefs :: SqlExpr (ValueList (Maybe PoolMetadataRefId))
    latestRefs =
      subList_select $ do
        pmr <- from $ table @PoolMetadataRef
        groupBy (pmr ^. PoolMetadataRefPoolId)
        pure $ max_ (pmr ^. PoolMetadataRefId)

    convert
        :: (Value PoolHashId, Value PoolMetadataRefId, Value Text, Value ByteString)
        -> PoolFetchRetry
    convert (Value phId, Value pmrId, Value url, Value pmh) =
      PoolFetchRetry
        { pfrPoolHashId = phId
        , pfrReferenceId = pmrId
        , pfrPoolUrl = PoolUrl url
        , pfrPoolMDHash = PoolMetaHash pmh
        , pfrRetry = newRetry now
        }

-- Get pool fetch data for pools that have previously errored.
queryPoolFetchRetry :: MonadIO m => UTCTime -> ReaderT SqlBackend m [PoolFetchRetry]
queryPoolFetchRetry _now = do
    res <- select $ do
      (ph :& pmr :& pofe) <-
        from $ table @PoolHash
        `innerJoin` table @PoolMetadataRef
        `on` (\(ph :& pmr) -> ph ^. PoolHashId ==. pmr ^. PoolMetadataRefPoolId)
        `innerJoin` table @PoolOfflineFetchError
        `on` (\(_ph :& pmr :& pofe) -> pofe ^. PoolOfflineFetchErrorPmrId ==. pmr ^. PoolMetadataRefId)
      where_ (just (pofe ^. PoolOfflineFetchErrorId) `in_` latestRefs)
      where_ (notExists $ from (table @PoolOfflineData) >>= \pod -> where_ (pod ^. PoolOfflineDataPmrId ==. pofe ^. PoolOfflineFetchErrorPmrId))
      orderBy [desc (pofe ^. PoolOfflineFetchErrorFetchTime)]
      pure
        ( pofe ^. PoolOfflineFetchErrorFetchTime
        , pofe ^. PoolOfflineFetchErrorPmrId
        , ph ^. PoolHashView
        , pmr ^. PoolMetadataRefHash
        , ph ^. PoolHashId
        , pofe ^. PoolOfflineFetchErrorRetryCount
        )
    pure $ map convert res
  where
    -- This assumes that the autogenerated `id` fiels is a reliable proxy for time, ie, higher
    -- `id` was added later. This is a valid assumption because the primary keys are
    -- monotonically increasing and never reused.
    latestRefs :: SqlExpr (ValueList (Maybe PoolOfflineFetchErrorId))
    latestRefs =
      subList_select $ do
        pofe <- from (table @PoolOfflineFetchError)
        groupBy (pofe ^. PoolOfflineFetchErrorPoolId)
        pure $ max_ (pofe ^. PoolOfflineFetchErrorId)

    convert
        :: (Value UTCTime, Value PoolMetadataRefId, Value Text, Value ByteString, Value PoolHashId, Value Word)
        -> PoolFetchRetry
    convert (Value time, Value pmrId, Value url, Value pmh, Value phId, Value rCount) =
      PoolFetchRetry
        { pfrPoolHashId = phId
        , pfrReferenceId = pmrId
        , pfrPoolUrl = PoolUrl url
        , pfrPoolMDHash = PoolMetaHash pmh
        , pfrRetry = retryAgain (Time.utcTimeToPOSIXSeconds time) rCount
        }
