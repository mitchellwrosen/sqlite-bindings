module Main where

import Control.Exception (SomeException, catch, mask, throwIO, uninterruptibleMask_)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Functor
import Data.IORef
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as Text
import Foreign.C.Types (CInt)
import Sqlite3.Bindings
import Test.Tasty
import Test.Tasty.HUnit

main :: IO ()
main = do
  withSqliteLibrary do
    (defaultMain . testGroup "tests")
      [ testCase "sqlite3_autovacuum_pages" test_sqlite3_autovacuum_pages,
        testCase "sqlite3_backup_*" test_sqlite3_backup,
        testCase "sqlite3_bind_*" test_sqlite3_bind,
        testCase "sqlite3_blob_*" test_sqlite3_blob,
        testCase "sqlite3_last_insert_rowid" test_sqlite3_last_insert_rowid,
        testCase "sqlite3_open / sqlite3_close" test_sqlite3_open
      ]

test_sqlite3_autovacuum_pages :: IO ()
test_sqlite3_autovacuum_pages = do
  withConnection ":memory:" \conn -> do
    countRef <- newIORef (0 :: Int)
    check (exec conn "pragma auto_vacuum = full")
    check (exec conn "create table foo(bar)")
    check (autovacuum_pages conn (Just \_ _ n _ -> modifyIORef' countRef (+ 1) $> n))
    check (exec conn "insert into foo values (1)")
    check (autovacuum_pages conn Nothing)
    check (exec conn "insert into foo values (1)")
    count <- readIORef countRef
    assertEqual "" 1 count

test_sqlite3_backup :: IO ()
test_sqlite3_backup = do
  withConnection ":memory:" \conn1 ->
    withConnection ":memory:" \conn2 ->
      withBackup (conn1, "main") (conn2, "main") \backup -> do
        sqlite3_backup_pagecount backup >>= assertEqual "" 0
        sqlite3_backup_remaining backup >>= assertEqual "" 0

  withConnection ":memory:" \conn1 ->
    withConnection ":memory:" \conn2 -> do
      check (exec conn1 "create table foo (bar)")
      check (exec conn1 "insert into foo values (1)")
      withBackup (conn1, "main") (conn2, "main") \backup -> do
        sqlite3_backup_pagecount backup >>= assertEqual "" 0
        sqlite3_backup_remaining backup >>= assertEqual "" 0
        backup_step backup 0 >>= assertEqual "" (Right ())
        sqlite3_backup_pagecount backup >>= assertEqual "" 2
        sqlite3_backup_remaining backup >>= assertEqual "" 2
        backup_step backup 1 >>= assertEqual "" (Right ())
        sqlite3_backup_remaining backup >>= assertEqual "" 1
        backup_step backup 1 >>= assertEqual "" (Left "no more rows available (101)")
        sqlite3_backup_remaining backup >>= assertEqual "" 0

-- TODO sqlite3_bind_pointer, sqlite3_bind_value
test_sqlite3_bind :: IO ()
test_sqlite3_bind = do
  withConnection ":memory:" \conn -> do
    withStatement conn "select ?" \(statement, _) -> do
      sqlite3_bind_parameter_count statement >>= assertEqual "" 1

      check (bind_blob statement 1 ByteString.empty)
      check (bind_blob statement 1 (ByteString.pack [0]))
      check (bind_double statement 1 0)
      check (bind_int statement 1 0)
      check (bind_int64 statement 1 0)
      check (bind_null statement 1)
      check (bind_text statement 1 "")
      check (bind_text statement 1 "foo")
      check (bind_zeroblob statement 1 0)
      check (bind_zeroblob statement 1 1)

      bind_int statement 0 0 >>= assertEqual "" (Left "column index out of range (25)")
      bind_int statement 2 0 >>= assertEqual "" (Left "column index out of range (25)")

    withStatement conn "select ?, :foo, @bar, $baz" \(statement, _) -> do
      sqlite3_bind_parameter_count statement >>= assertEqual "" 4
      sqlite3_bind_parameter_index statement ":foo" >>= assertEqual "" (Just 2)
      sqlite3_bind_parameter_index statement "@bar" >>= assertEqual "" (Just 3)
      sqlite3_bind_parameter_index statement "$baz" >>= assertEqual "" (Just 4)
      sqlite3_bind_parameter_name statement 0 >>= assertEqual "" Nothing
      sqlite3_bind_parameter_name statement 1 >>= assertEqual "" Nothing
      sqlite3_bind_parameter_name statement 2 >>= assertEqual "" (Just ":foo")
      sqlite3_bind_parameter_name statement 3 >>= assertEqual "" (Just "@bar")
      sqlite3_bind_parameter_name statement 4 >>= assertEqual "" (Just "$baz")

test_sqlite3_blob :: IO ()
test_sqlite3_blob = do
  withConnection ":memory:" \conn -> do
    check (exec conn "create table foo (bar)")
    check (exec conn "insert into foo values (x'01020304')")
    rowid <- sqlite3_last_insert_rowid conn
    withBlob conn "main" "foo" "bar" rowid True \blob -> do
      blob_read blob 0 0 >>= assertEqual "" (Right ByteString.empty)
      blob_read blob 2 0 >>= assertEqual "" (Right (ByteString.pack [1, 2]))
      blob_read blob 2 2 >>= assertEqual "" (Right (ByteString.pack [3, 4]))
      blob_read blob 5 0 >>= assertEqual "" (Left "SQL logic error (1)")
      blob_read blob 0 5 >>= assertEqual "" (Left "SQL logic error (1)")

test_sqlite3_last_insert_rowid :: IO ()
test_sqlite3_last_insert_rowid = do
  withConnection ":memory:" \conn -> do
    sqlite3_last_insert_rowid conn >>= assertEqual "" 0
    check (exec conn "create table foo (bar)")
    check (exec conn "insert into foo values (1)")
    sqlite3_last_insert_rowid conn >>= assertEqual "" 1
    check (exec conn "create table bar (baz primary key) without rowid")
    check (exec conn "insert into bar values (1)")
    check (exec conn "insert into bar values (2)")
    sqlite3_last_insert_rowid conn >>= assertEqual "" 1

test_sqlite3_open :: IO ()
test_sqlite3_open = do
  withConnection ":memory:" \_ -> pure ()
  withConnection "" \_ -> pure ()

------------------------------------------------------------------------------------------------------------------------
-- Exception-safe acquire/release actions

withConnection :: Text -> (Sqlite3 -> IO a) -> IO a
withConnection name =
  brackety (open name) close

withBackup :: (Sqlite3, Text) -> (Sqlite3, Text) -> (Sqlite3_backup -> IO a) -> IO a
withBackup (conn1, name1) (conn2, name2) =
  brackety (backup_init conn2 name2 conn1 name1) backup_finish

withBlob :: Sqlite3 -> Text -> Text -> Text -> Int64 -> Bool -> (Sqlite3_blob -> IO a) -> IO a
withBlob conn database table column rowid mode =
  brackety (blob_open conn database table column rowid mode) blob_close

withSqliteLibrary :: IO a -> IO a
withSqliteLibrary action =
  brackety initialize (\() -> shutdown) \() -> action

withStatement :: Sqlite3 -> Text -> ((Sqlite3_stmt, Text) -> IO a) -> IO a
withStatement conn sql =
  brackety (prepare_v2 conn sql) (\(statement, _) -> finalize statement)

brackety :: IO (Either Text a) -> (a -> IO (Either Text ())) -> (a -> IO b) -> IO b
brackety acquire release action =
  mask \restore -> do
    value <- check (restore acquire)
    let cleanup = uninterruptibleMask_ (release value)
    result <-
      restore (action value) `catch` \(exception :: SomeException) -> do
        void cleanup
        throwIO exception
    check cleanup
    pure result

------------------------------------------------------------------------------------------------------------------------
-- API wrappers that return Either Text

autovacuum_pages :: Sqlite3 -> Maybe (Text -> Word -> Word -> Word -> IO Word) -> IO (Either Text ())
autovacuum_pages conn callback = do
  code <- sqlite3_autovacuum_pages conn callback
  pure (inspect code ())

backup_finish :: Sqlite3_backup -> IO (Either Text ())
backup_finish backup = do
  code <- sqlite3_backup_finish backup
  pure (inspect code ())

backup_init :: Sqlite3 -> Text -> Sqlite3 -> Text -> IO (Either Text Sqlite3_backup)
backup_init dstConnection dstName srcConnection srcName =
  sqlite3_backup_init dstConnection dstName srcConnection srcName >>= \case
    Nothing -> Left <$> sqlite3_errmsg dstConnection
    Just backup -> pure (Right backup)

backup_step :: Sqlite3_backup -> Int -> IO (Either Text ())
backup_step backup n = do
  code <- sqlite3_backup_step backup n
  pure (inspect code ())

bind_blob :: Sqlite3_stmt -> Int -> ByteString -> IO (Either Text ())
bind_blob statement index blob = do
  code <- sqlite3_bind_blob statement index blob
  pure (inspect code ())

bind_double :: Sqlite3_stmt -> Int -> Double -> IO (Either Text ())
bind_double statement index n = do
  code <- sqlite3_bind_double statement index n
  pure (inspect code ())

bind_int :: Sqlite3_stmt -> Int -> Int -> IO (Either Text ())
bind_int statement index n = do
  code <- sqlite3_bind_int statement index n
  pure (inspect code ())

bind_int64 :: Sqlite3_stmt -> Int -> Int64 -> IO (Either Text ())
bind_int64 statement index n = do
  code <- sqlite3_bind_int64 statement index n
  pure (inspect code ())

bind_null :: Sqlite3_stmt -> Int -> IO (Either Text ())
bind_null statement index = do
  code <- sqlite3_bind_null statement index
  pure (inspect code ())

bind_text :: Sqlite3_stmt -> Int -> Text -> IO (Either Text ())
bind_text statement index string = do
  code <- sqlite3_bind_text statement index string
  pure (inspect code ())

bind_zeroblob :: Sqlite3_stmt -> Int -> Int -> IO (Either Text ())
bind_zeroblob statement index n = do
  code <- sqlite3_bind_zeroblob statement index n
  pure (inspect code ())

blob_close :: Sqlite3_blob -> IO (Either Text ())
blob_close blob = do
  code <- sqlite3_blob_close blob
  pure (inspect code ())

blob_open :: Sqlite3 -> Text -> Text -> Text -> Int64 -> Bool -> IO (Either Text Sqlite3_blob)
blob_open conn database table column rowid mode = do
  (maybeBlob, code) <- sqlite3_blob_open conn database table column rowid mode
  case maybeBlob of
    Nothing -> pure (inspect code undefined)
    Just blob -> do
      let result = inspect code blob
      case result of
        Left _ -> void (blob_close blob)
        Right _ -> pure ()
      pure result

blob_read :: Sqlite3_blob -> Int -> Int -> IO (Either Text ByteString)
blob_read blob len offset =
  sqlite3_blob_read blob len offset <&> \case
    Left code -> inspect code undefined
    Right bytes -> Right bytes

close :: Sqlite3 -> IO (Either Text ())
close conn = do
  code <- sqlite3_close conn
  pure (inspect code ())

-- TODO take callback
exec :: Sqlite3 -> Text -> IO (Either Text ())
exec conn sql = do
  (maybeErrorMsg, code) <- sqlite3_exec conn sql Nothing
  pure case inspect code () of
    Left errorMsg -> Left (errorMsg <> maybe Text.empty ("; " <>) maybeErrorMsg)
    Right () -> Right ()

finalize :: Sqlite3_stmt -> IO (Either Text ())
finalize statement = do
  code <- sqlite3_finalize statement
  pure (inspect code ())

initialize :: IO (Either Text ())
initialize = do
  code <- sqlite3_initialize
  pure (inspect code ())

open :: Text -> IO (Either Text Sqlite3)
open name = do
  (maybeConn, code) <- sqlite3_open name
  case maybeConn of
    Nothing -> pure (inspect code undefined)
    Just conn -> do
      let result = inspect code conn
      case result of
        Left _ -> void (close conn)
        Right _ -> pure ()
      pure result

prepare_v2 :: Sqlite3 -> Text -> IO (Either Text (Sqlite3_stmt, Text))
prepare_v2 conn sql = do
  (maybeStatement, unusedSql, code) <- sqlite3_prepare_v2 conn sql
  pure case maybeStatement of
    Nothing -> inspect code undefined
    Just statement -> Right (statement, unusedSql)

shutdown :: IO (Either Text ())
shutdown = do
  code <- sqlite3_shutdown
  pure (inspect code ())

------------------------------------------------------------------------------------------------------------------------
-- Test helpers

check :: IO (Either Text a) -> IO a
check action =
  action >>= \case
    Left msg -> assertFailure (Text.unpack msg)
    Right result -> pure result

inspect :: CInt -> a -> Either Text a
inspect code result =
  if code == _SQLITE_OK
    then Right result
    else Left (sqlite3_errstr code <> " (" <> Text.pack (show code) <> ")")
