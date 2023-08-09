# http-download changelog

## 0.2.1.0

* Depend on `crypton` instead of `cryptonite`. No changes to API.

## 0.2.0.0

* Add new field `drForceDownload` to `DownloadRequest` to allow force download even if the file exists
* Add new value `DownloadHttpError` for `VerifiedDownloadException` type
* Switch `DownloadRequest` fields over to smart constructors + setters

## 0.1.0.1

* Handle concurrent downloads of same file better [#1](https://github.com/commercialhaskell/http-download/pull/1)

## 0.1.0.0

Initial release
