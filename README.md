# CeX Bar

A macOS menu bar app that watches [CeX UK](https://uk.webuy.com) stock for anything you search for, and notifies you when new listings turn up.

- Search for anything — games, phones, laptops, films — and narrow it by department and category
- Filter on the attributes CeX has for those results (RAM, capacity, screen size, network, grade, colour…), with "and up" for sizes
- Must-contain / exclude keywords, price range, specific stores, online only
- Checks on a schedule (15 min – 3 hours) and sends a notification for new listings; click one to open it on CeX

It uses the same search service (Algolia) that uk.webuy.com's own search page uses, with the public search-only key the site gives every browser. It's unofficial and may break if CeX changes their site.

## Install

Download the latest `CeX-Bar-*.zip` from [Releases](https://github.com/joshjkns/cexbar/releases), unzip it, and move **CeX Bar.app** to Applications.

The app is ad-hoc signed, not notarised, so macOS will block it the first time. Either right-click it → **Open**, or run:

```sh
xattr -dr com.apple.quarantine "/Applications/CeX Bar.app"
```

Requires macOS 13 or later.

## Build from source

Needs Xcode or the Command Line Tools (`xcode-select --install`).

```sh
./build.sh                         # builds "CeX Bar.app" for this Mac
UNIVERSAL=1 VERSION=1.2.0 ./build.sh   # Apple Silicon + Intel, with a version number
```

## Releasing

Push a version tag and GitHub Actions builds a universal app and attaches it to a release:

```sh
git tag v1.2.0 && git push origin v1.2.0
```
