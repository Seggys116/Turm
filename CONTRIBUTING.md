# Contributing

Bug reports and pull requests are welcome. For anything bigger than a small fix, open an issue first so we can agree on the approach before you spend time on it.

## Building and testing

Follow the build steps in the [README](README.md#building). To run the tests locally:

```
swift test --package-path Packages/TurmCore
xcodebuild test -project Turm.xcodeproj -scheme Turm -destination 'platform=macOS' -only-testing:TurmTests
```

`Scripts/demo.sh` rebuilds the README screenshot of the Mac app from mocked data in a Debug build.

Code shared by the Mac and iOS apps lives in `Packages/TurmCore`. A feature that makes sense on both platforms should work on both.

## Pull requests

- Keep each pull request to one change and add tests for new behaviour.
- Write commit messages as a sentence saying what the change does and why, like the existing history.
- Update the page in [docs](docs/README.md) when you change something it describes.
