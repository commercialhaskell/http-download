# Changelog for `http-download`

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to the
[Haskell Package Versioning Policy](https://pvp.haskell.org/).

## 0.2.2.0 - 2026-07-01

* Depend on package `ram` instead of `memory`. No changes to API.

## 0.2.1.0 - 2023-08-09

* Depend on package `crypton` instead of `cryptonite`. No changes to API.

## 0.2.0.0 - 2020-03-03

* Add new field `drForceDownload` to `DownloadRequest` to allow force download
  even if the file exists.
* Add new value `DownloadHttpError` for `VerifiedDownloadException` type.
* Switch `DownloadRequest` fields over to smart constructors + setters.

## 0.1.0.1 - 2019-12-23

* Handle concurrent downloads of same file better
  [#1](https://github.com/commercialhaskell/http-download/pull/1).

## 0.1.0.0 - 2019-06-08

* Initial release.
