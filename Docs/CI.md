# CI / CD

| Workflow | When | What |
| --- | --- | --- |
| `ci.yml` | Every push and pull request | Generates the project, runs unit tests on a simulator, builds Release for a generic device (unsigned). |
| `testflight.yml` | Push to `main` (code changes), or manual | Archives, signs (automatic signing with an App Store Connect API key), and uploads to TestFlight. |

Build number = `BUILD_NUMBER_BASE` (variable, default 0) + run number.

## Repository settings

| Name | Kind | Purpose |
| --- | --- | --- |
| `APP_STORE_CONNECT_API_KEY_ID` | secret | API key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | secret | API issuer ID |
| `APP_STORE_CONNECT_API_KEY_P8_BASE64` | secret | base64 of the `.p8` |
| `APPLE_CERTIFICATE_P12_BASE64`, `APPLE_CERTIFICATE_PASSWORD` | secret | Apple Distribution certificate, if automatic signing cannot supply one |
| `DEVELOPMENT_TEAM` | variable | Team ID |
| `BUILD_NUMBER_BASE`, `CI_MACOS_RUNNER`, `CI_XCODE_APP` | variable | Optional overrides |

Pull requests from forks never receive secrets; the TestFlight workflow does
not run on pull requests.

The App Store Connect app record must exist before the first upload.
