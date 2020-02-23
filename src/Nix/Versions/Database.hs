 {-# LANGUAGE DeriveGeneric #-}
 {-# LANGUAGE OverloadedStrings #-}
 {-# LANGUAGE DerivingStrategies #-}
 {-# LANGUAGE GeneralizedNewtypeDeriving #-}
 {-# LANGUAGE NamedFieldPuns #-}

{-| This file handles the creation of a database of versions
   from package information coming from Nix
-}
module Nix.Versions.Database
    ( create
    , versions
    , VersionInfo(..)
    , PackageDB
    , createSQLDatabase
    ) where

import Data.Aeson (ToJSON, FromJSON, eitherDecodeFileStrict)
import Data.HashMap.Strict (HashMap)
import Data.Maybe (fromMaybe)
import Data.Text (Text, pack, unpack)
import Data.Time.Calendar (Day(..), toModifiedJulianDay)
import GHC.Generics (Generic)
import Nix.Versions.Types (Hash(..), Version(..), Name(..), Commit(..))
import Nix.Versions.Json (PackagesJSON(PackagesJSON), InfoJSON)

import qualified Database.SQLite.Simple as SQL
import Database.SQLite.Simple (ToRow(toRow), FromRow(fromRow), SQLData(..))

import qualified Nix.Versions.Json as Json
import qualified Data.HashMap.Strict as HashMap

versions :: PackageDB -> Name -> Maybe [(Version, VersionInfo)]
versions (PackageDB db) name = HashMap.toList <$> HashMap.lookup name db

packageCount :: PackageDB -> Int
packageCount = HashMap.size . unPackageDB

packageNames :: PackageDB -> [Name]
packageNames = HashMap.keys . unPackageDB

-- PackageDB

newtype PackageDB = PackageDB { unPackageDB :: HashMap Name Versions }
    deriving newtype (ToJSON, FromJSON)

instance Semigroup PackageDB where
    (<>) = merge

instance Monoid PackageDB where
    mempty = PackageDB mempty

type Versions = HashMap Version VersionInfo

data VersionInfo = VersionInfo
    { revision :: Hash
    , description :: Maybe Text
    , nixpath :: Maybe FilePath
    , date :: Day
    } deriving (Show, Eq, Generic)

instance ToJSON VersionInfo
instance FromJSON VersionInfo

create :: PackagesJSON -> PackageDB
create (PackagesJSON (Commit revision date) packages) = PackageDB $ HashMap.map toVersionInfo packages
    where
        toVersionInfo :: InfoJSON -> HashMap Version VersionInfo
        toVersionInfo info =
            HashMap.singleton (Json.version info) $ VersionInfo
                { revision = revision
                , description = Json.description info
                , nixpath = Json.nixpkgsPath info
                , date = date
                }

merge :: PackageDB -> PackageDB -> PackageDB
merge (PackageDB db1) (PackageDB db2) =
    PackageDB $ HashMap.unionWith (HashMap.unionWith mergeInfos) db1 db2
    where
        mergeInfos info1 info2 =
            if date info1 > date info2
               then info1
               else info2

--------------------------------------------------------------------------------
-- Saving on Disk

db_FILE_NAME = "SQL_DATABASE.db"
db_PACKAGE_NAMES = "PACKAGE_NAMES"
db_PACKAGE_VERSIONS = "PACKAGE_VERSIONS"

createSQLDatabase :: IO ()
createSQLDatabase = do
    conn <- SQL.open db_FILE_NAME
    SQL.execute_ conn $ "CREATE TABLE IF NOT EXISTS  " <> db_PACKAGE_NAMES <> " "
                        <> "( ID INTEGER PRIMARY KEY"
                        <> ", PACKAGE_NAME TEXT UNIQUE"
                        <> ")"

    SQL.execute_ conn $ "CREATE TABLE IF NOT EXISTS  " <> db_PACKAGE_VERSIONS <> " "
                        <> "( PACKAGE_NAME TEXT NOT NULL"
                        <> ", VERSION_NAME TEXT NOT NULL"
                        <> ", REVISION_HASH TEXT NOT NULL"
                        <> ", DESCRIPTION TEXT"
                        <> ", NIXPATH TEXT"
                        <> ", DAY INTEGER NOT NULL"
                        <> ", PRIMARY KEY (PACKAGE_NAME, VERSION_NAME)"
                        <> ", FOREIGN KEY (PACKAGE_NAME) REFERENCES " <> db_PACKAGE_NAMES <> "(PACKAGE_NAME)"
                        <> ")"

newtype SQLPackageName = SQLPackageName Name

instance ToRow SQLPackageName where
    toRow (SQLPackageName (Name name)) = [SQLText name]

instance FromRow SQLPackageName where
    fromRow = (SQLPackageName . Name) <$> SQL.field

newtype SQLPackageVersion = SQLPackageVersion (Name, Version, VersionInfo)

instance ToRow SQLPackageVersion where
    toRow (SQLPackageVersion (name, version, VersionInfo { revision, description , nixpath, date })) =
        [ SQLText $ fromName name
        , SQLText $ fromVersion version
        , SQLText $ fromHash revision
        , nullable $ SQLText <$> description
        , nullable $ SQLText . pack <$> nixpath
        , SQLInteger $ fromInteger $ toModifiedJulianDay date
        ]

nullable :: Maybe SQLData -> SQLData
nullable = fromMaybe SQLNull

instance FromRow SQLPackageVersion where
    fromRow = create
            <$> SQL.field
            <*> SQL.field
            <*> SQL.field
            <*> SQL.field
            <*> SQL.field
            <*> SQL.field
        where
            create :: Text -> Text -> Text -> Maybe Text -> Maybe Text -> Integer -> SQLPackageVersion
            create name version revision description nixpath date =
                SQLPackageVersion
                    ( Name name
                    , Version version
                    , VersionInfo
                        { revision = Hash revision
                        , description = description
                        , nixpath = unpack <$> nixpath
                        , date = ModifiedJulianDay $ fromInteger date
                        }
                    )

