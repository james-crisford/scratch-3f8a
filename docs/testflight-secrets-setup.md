# TestFlight secrets setup — 30 min after Apple approval

When your Apple Developer Program enrolment clears, follow this once. After that, every push to main → CI → TestFlight automatically.

## Prerequisites
- Apple Developer Program active (£79/yr)
- Repo open in browser (github.com/james-crisford/PuttingLab)
- developer.apple.com signed in

## 1. App Store Connect API key (5 min)

Best path — no Mac needed.

1. Go to **appstoreconnect.apple.com** → Users and Access → Integrations → App Store Connect API
2. Click **Generate API Key** (or "+ Add Key")
3. Name: `puttinglab-ci`
4. Access: **App Manager** (lets it upload to TestFlight)
5. Click Generate, then **Download the .p8 file IMMEDIATELY** — you can only download it once
6. Note the **Key ID** (10-char) and **Issuer ID** (UUID) on the same page

Encode the .p8 as base64 (on Windows PowerShell):
```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("AuthKey_XXXXX.p8")) | Set-Clipboard
```
Or on bash:
```bash
base64 -w0 AuthKey_XXXXX.p8 | pbcopy
```

Add to GitHub repo → Settings → Secrets and variables → Actions:
- `APP_STORE_CONNECT_API_KEY` = the base64
- `APP_STORE_CONNECT_KEY_ID` = the 10-char key ID
- `APP_STORE_CONNECT_ISSUER_ID` = the UUID

## 2. Bundle ID + Team ID (5 min)

1. developer.apple.com → Account → **Membership** tab → copy your **Team ID** (10-char)
2. developer.apple.com → Account → **Identifiers** → **+** → App IDs → App
3. Description: `PuttingLab`
4. Bundle ID: **Explicit**, e.g. `com.jamescrisford.puttinglab` (must be unique across all of Apple)
5. Capabilities: tick **ARKit** (and any others you might use later)
6. Register

Add to GitHub secrets:
- `APPLE_TEAM_ID` = your 10-char Team ID
- `APP_BUNDLE_ID` = `com.jamescrisford.puttinglab` (whatever you chose)

## 3. Signing certificate (10 min — needs a Mac OR a workaround)

The standard way needs a Mac to generate a CSR. Three options:

### Option A: Borrow a Mac for 10 minutes
1. On the Mac: Keychain Access → Certificate Assistant → Request a Certificate From a Certificate Authority
2. Email: your Apple ID email; Common Name: your name; "Saved to disk", "Let me specify key pair"
3. Generates a `CertificateSigningRequest.certSigningRequest` file
4. developer.apple.com → Certificates → **+** → **Apple Distribution** → upload the CSR → download the `.cer`
5. Double-click `.cer` to install in Keychain
6. In Keychain Access → My Certificates → right-click the "Apple Distribution: <your name>" → **Export** as `.p12` (set a password — remember it)

### Option B: Use openssl from Windows (no Mac needed, more fiddly)
- Generate a private key + CSR with `openssl` on Windows (3 commands)
- Upload CSR to developer.apple.com → download cert
- Combine cert + key into a `.p12` with `openssl pkcs12 -export`
- Detailed instructions in any "iOS code signing without a Mac" guide on the web

Either way, you end up with a `.p12` file + a password.

Encode the `.p12` as base64 (PowerShell):
```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("ios_distribution.p12")) | Set-Clipboard
```

Add to GitHub secrets:
- `SIGNING_CERT_P12_BASE64` = the base64
- `SIGNING_CERT_PASSWORD` = the password you chose during export

## 4. Provisioning profile (5 min)

1. developer.apple.com → Profiles → **+** → **App Store** (under Distribution)
2. App ID: the one you just created
3. Certificate: the distribution cert you just uploaded
4. Profile Name: `PuttingLab App Store`
5. Generate → Download → you get a `.mobileprovision` file

Encode as base64:
```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("PuttingLab_App_Store.mobileprovision")) | Set-Clipboard
```

Add to GitHub secrets:
- `PROVISIONING_PROFILE_B64` = the base64

## 5. First upload

In your GitHub repo:
1. Actions tab → **Test** workflow → **Run workflow**
2. Tick **release** (the boolean input)
3. Click Run

The workflow will:
- Run all 311 tests
- Sign the IPA with your cert
- Upload to App Store Connect
- After ~10 min, the build shows in TestFlight on your iPhone

If a secret is missing, the workflow fails early with a clear error.

## 6. Set up automatic TestFlight on every push (optional)

After the first manual run works, edit `.github/workflows/test.yml` and change the `release` job's `if` line from:
```yaml
if: github.event_name == 'workflow_dispatch' && github.event.inputs.release == 'true'
```
to:
```yaml
if: github.ref == 'refs/heads/main' && github.event_name == 'push'
```

Now every push to main → 5 min later → new TestFlight build on your iPhone.

## Total secret count: 8

- `SIGNING_CERT_P12_BASE64`
- `SIGNING_CERT_PASSWORD`
- `PROVISIONING_PROFILE_B64`
- `APP_STORE_CONNECT_API_KEY`
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- `APPLE_TEAM_ID`
- `APP_BUNDLE_ID`

## Estimated total time

~30 min if you borrow a Mac for the cert step. ~1 hour if you do it openssl-from-Windows.
