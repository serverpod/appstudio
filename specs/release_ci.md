# Releasing from GitHub Actions

Two workflows do in CI what `make release` and `make promote` do on a release
Mac, with the same scripts and the same gates.

| Workflow | Runs | Does | Reaches users |
|---|---|---|---|
| `release.yml` | after CI passes on a push to `main`, or by hand | builds, signs and notarizes macOS; takes the Windows installer CI built; uploads both, preview only | no |
| `promote.yml` | by hand only, after a reviewer approves | adds the uploaded builds to the appcasts | yes |

## When something is uploaded

**On every push to `main` that names a build that is not in the bucket yet.**
`tool/release_plan.sh` checks it for each platform:

- macOS: `pubspec.yaml`'s `version: X.Y.Z+N`, object
  `releases/macos/X.Y.Z/bN/AppStudio-X.Y.Z-arm64.zip`.
- Windows: the same `X.Y.Z` plus `windows/release.json`'s `build`, object
  `releases/windows/X.Y.Z/bN/AppStudio-X.Y.Z-x64-setup.exe`.

If the object's `.sha256` sidecar is already in the bucket, that platform is
skipped. This is the case for most pushes, and the run takes seconds. If it is
missing and the build number beats everything published (the appcast *and*
`downloads/<os>.json`, which also lists uploads not yet promoted), the build is
uploaded. If it is missing but the number is already used, the run fails and
names the fix. Repeating a build number cannot be undone, so the run never
guesses one.

This is the recommended answer to "upload when the version changes, or what?":

- **The version bump is the release decision.** `make set_version` picks the
  build number from the live bucket. Committing its result is what asks for a
  release, so there is no tag to keep in step with `pubspec.yaml`.
- **Uploading on every push could not work anyway.** Signing and notarizing
  make every build's bytes different, and published objects are immutable.
- **Only commits that passed CI are released.** The workflow is chained to CI
  (`workflow_run`), and the Windows installer is the very artifact CI built
  and tested alongside. "Passed" means the `macos-latest`, `windows-latest`
  and `windows installer` jobs succeeded. Release checks those jobs by name,
  so a job added to CI later that is allowed to fail cannot block a
  release.

So a release is:

```bash
make set_version V=1.2.3          # both build counters, from the live bucket
git commit -am "chore: Release 1.2.3." && git push
```

`make set_version` writes `pubspec.yaml` (macOS counter) and
`windows/release.json` (Windows counter). Each new number clears that
platform's appcast and download manifest, so neither can repeat.

Watch **Actions → Release**. Its summary shows the direct download URL of each
upload. Install those builds on a clean Mac and a clean PC. When they check
out, run **Actions → Promote → Run workflow** on `main`, type `1.2.3`, and
approve the `production` deployment.

**Windows is skipped until `windows/release.json` has `appcastUrl` and
`eddsaPublicKey`.** That is today's state. A build without them never checks
for updates, so anyone who installed it would stay on it. Step 4 below sets
them.

**Testing the signing setup without a release:** run **Actions → Release →
Run workflow** with *test_macos_build* ticked. It builds, signs and notarizes
macOS, then keeps the zip as a run artifact for 7 days. It uploads nothing and
needs no Google Cloud access.

## What promote does

The plan job reads what `main` names, checks that you typed the same version,
and lists what each platform would promote. Each platform needs its build
uploaded and newer than its appcast; a platform already promoted is skipped.
The plan job ends before anyone is asked to approve if a platform you asked
for cannot be promoted.

The `macos` and `windows` jobs then wait for a `production` reviewer. Once
approved, they run:

- `tool/publish_appcast.sh` with `SPARKLE_ED_KEY_FILE` set. It checks the key's
  public half against `SPARKLE_PUBLIC_ED_KEY` in `Sparkle.xcconfig` (derived
  by `tool/lib/eddsa_public_key.py`, since there is no Keychain to ask), then
  signs with `generate_appcast --ed-key-file`.
- `tool/windows/promote_release.ps1`. It checks the key against
  `eddsaPublicKey` in `windows/release.json` (`winsparkle-tool public-key`), and
  checks the new signature against that same public key (`winsparkle-tool
  verify`).

Each key is written to the runner's temp directory, outside the checkout, and
deleted when its step ends.

## One-time setup

The commands use these names; change them if you like, but keep them
consistent.

```bash
PROJECT=serverpod-appstudio              # the project holding the bucket and the CDN
BUCKET=serverpod-appstudio-toolchain
REPO=serverpod/appstudio
REPO_ID=1305101557                       # gh api repos/serverpod/appstudio --jq .id
PROJECT_NUMBER=$(gcloud projects describe $PROJECT --format='value(projectNumber)')
```

### 1. GitHub environments

Settings → Environments → New environment:

- **`release-upload`**
  - Deployment branches and tags: *Selected branches*, `main`.
  - No reviewers. It holds the Apple secrets, and its Google identity can only
    add previews.
- **`production`**
  - Deployment branches: *Selected branches*, `main`.
  - **Required reviewers**: you, and preferably a second person.
  - Leave *Prevent self-review* off while you are the only reviewer.
    Otherwise nobody can approve.
  - Untick *Allow administrators to bypass configured protection rules*.

Settings → Actions → General: leave *Workflow permissions* at **Read
repository contents**. The workflows ask for anything more themselves.

### 2. Apple: Developer ID certificate and a notary key

**Developer ID Application certificate, as a `.p12`.** Export it on the Mac
that signs releases today:

1. Open Keychain Access → login → My Certificates.
2. Expand **Developer ID Application: Serverpod AB (WK2NRY4GS4)** so its
   private key shows.
3. Select both, choose File → Export Items…, and save as `.p12` with a strong
   password.

Without the private key the file is useless. Then upload it:

```bash
base64 -i ~/Desktop/DeveloperID.p12 | gh secret set MACOS_DEVELOPER_ID_P12 --env release-upload --repo $REPO
gh secret set MACOS_DEVELOPER_ID_P12_PASSWORD --env release-upload --repo $REPO   # prompts
rm -P ~/Desktop/DeveloperID.p12
```

The job imports it into a throwaway keychain and fetches Apple's Developer ID
G2 intermediate. It deletes that keychain afterwards.

**App Store Connect API key for `notarytool`.** Give CI its own key, so it can
be revoked without touching the release Mac's `appstudio` profile:

1. Open App Store Connect → Users and Access → Integrations → App Store
   Connect API → Team Keys.
2. Choose **+**, name the key `GitHub Actions notarization`, and give it the
   **Developer** access role.
3. Download `AuthKey_XXXXXXXXXX.p8`. It can only be downloaded once.
4. Note the Key ID and the Issuer ID shown on that page.

```bash
gh secret set APPLE_NOTARY_API_KEY_P8 --env release-upload --repo $REPO < ~/Downloads/AuthKey_XXXXXXXXXX.p8
gh secret set APPLE_NOTARY_API_KEY_ID --env release-upload --repo $REPO --body XXXXXXXXXX
gh secret set APPLE_NOTARY_API_ISSUER_ID --env release-upload --repo $REPO --body xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

Keep the `.p8` in your password manager, or delete it; a lost one is simply
revoked and replaced. `tool/distribute_macos.sh` passes it to `notarytool` as
`--key/--key-id/--issuer` when `NOTARY_KEY_PATH` is set, and uses the keychain
profile otherwise, so `make build` on a Mac is unchanged.

Now run **Release** with *test_macos_build* ticked to prove this half before
going on.

### 3. The Sparkle key (macOS appcast)

It lives in the release Mac's login Keychain. Export it into a temporary
directory **outside the repo**, check it is the key the app ships, store it,
and delete the export:

```bash
cd ~/Projects/appstudio
d=$(mktemp -d); chmod 700 "$d"
.sparkle-tools/2.9.5/bin/generate_keys -x "$d/sparkle.key"
python3 tool/lib/eddsa_public_key.py "$d/sparkle.key"
grep SPARKLE_PUBLIC_ED_KEY macos/Runner/Configs/Sparkle.xcconfig   # must be the same string
gh secret set SPARKLE_ED25519_PRIVATE_KEY --env production --repo $REPO < "$d/sparkle.key"
rm -P "$d/sparkle.key"; rmdir "$d"
```

The release Mac's Keychain keeps its copy, so `make promote` still works. The
off-site backup AGENTS.md asks for (Secret Manager, somewhere without bucket
write access) is still needed: a GitHub secret cannot be read back, so it is
not a backup.

**The trade-off of promoting from CI:** the `production` environment now holds
both the signing key and, through its Google identity, write access to the
appcast. Before, nothing held both. The required reviewers, the `main`-only
branch rule and the identity bound to that one environment are what stand in
for that separation. Anyone with admin rights on the repository can change
those settings, so keep that group small.

### 4. The WinSparkle key (Windows appcast) and `windows/release.json`

There is no Windows key yet. Generate one with WinSparkle's own tool on the
Windows machine, after any build there has fetched it:

```powershell
build\windows\x64\winsparkle\WinSparkle-0.9.4\bin\winsparkle-tool.exe generate-key --file $env:TEMP\winsparkle.key
```

On a Mac instead, the same file can be made directly. WinSparkle reads a
base64 32-byte ed25519 seed, and promote checks the pair with
`winsparkle-tool` before it signs anything:

```bash
d=$(mktemp -d); chmod 700 "$d"
head -c 32 /dev/urandom | base64 > "$d/winsparkle.key"
python3 tool/lib/eddsa_public_key.py "$d/winsparkle.key"   # the public key
```

Then:

```bash
gh secret set WINSPARKLE_ED25519_PRIVATE_KEY --env production --repo $REPO < "$d/winsparkle.key"
# back it up next to the Sparkle key, but separately from it, then:
rm -P "$d/winsparkle.key"; rmdir "$d"
```

Set `windows/release.json`:

```json
{
  "build": 1,
  "appcastUrl": "https://asdl.serverpod.dev/appcast/windows/appcast.xml",
  "eddsaPublicKey": "<the public key printed above>"
}
```

Commit it. The next Release run uploads Windows build 1 as a preview. Builds
from before this commit have no feed and will never update themselves;
reinstall them by hand.

### 5. Google Cloud: Workload Identity Federation, no JSON keys

GitHub's OIDC token is exchanged for a short-lived token of one of two
service accounts. Each account is bound to exactly one GitHub environment of
this repository, so neither a pull request nor another branch can get either.

```bash
gcloud services enable iamcredentials.googleapis.com sts.googleapis.com --project=$PROJECT

gcloud iam workload-identity-pools create github --project=$PROJECT \
  --location=global --display-name="GitHub Actions"

gcloud iam workload-identity-pools providers create-oidc appstudio --project=$PROJECT \
  --location=global --workload-identity-pool=github \
  --display-name="serverpod/appstudio" \
  --issuer-uri=https://token.actions.githubusercontent.com \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.environment=assertion.environment" \
  --attribute-condition="assertion.repository_id=='$REPO_ID' && assertion.ref=='refs/heads/main'"

POOL=projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/github
UPLOAD_SA=appstudio-release-upload@$PROJECT.iam.gserviceaccount.com
PROMOTE_SA=appstudio-release-promote@$PROJECT.iam.gserviceaccount.com

gcloud iam service-accounts create appstudio-release-upload --project=$PROJECT \
  --display-name="App Studio release: upload previews (GitHub)"
gcloud iam service-accounts create appstudio-release-promote --project=$PROJECT \
  --display-name="App Studio release: promote to the appcast (GitHub)"

# The subject of a job that uses an environment is repo:<repo>:environment:<name>.
gcloud iam service-accounts add-iam-policy-binding $UPLOAD_SA --project=$PROJECT \
  --role=roles/iam.workloadIdentityUser \
  --member="principal://iam.googleapis.com/$POOL/subject/repo:$REPO:environment:release-upload"
gcloud iam service-accounts add-iam-policy-binding $PROMOTE_SA --project=$PROJECT \
  --role=roles/iam.workloadIdentityUser \
  --member="principal://iam.googleapis.com/$POOL/subject/repo:$REPO:environment:production"
```

The condition matches on `repository_id`, not the name, so a deleted and
re-created `serverpod/appstudio` cannot inherit the binding.

**Bucket roles, scoped by object prefix.** Conditions on bucket roles need
uniform bucket-level access. Check it first, and turn it on only if nothing
still relies on per-object ACLs:

```bash
gcloud storage buckets describe gs://$BUCKET --format='value(uniform_bucket_level_access)'
# gcloud storage buckets update gs://$BUCKET --uniform-bucket-level-access
```

```bash
prefix() { echo "resource.name.startsWith(\"projects/_/buckets/$BUCKET/objects/$1\")"; }

# Upload: may CREATE under releases/ (objectCreator cannot overwrite or delete,
# so IAM now enforces the immutability --if-generation-match=0 asks for),
# and rewrite the downloads/ pointers.
gcloud storage buckets add-iam-policy-binding gs://$BUCKET --member=serviceAccount:$UPLOAD_SA \
  --role=roles/storage.objectCreator \
  --condition="expression=$(prefix releases/),title=releases-create-only"
gcloud storage buckets add-iam-policy-binding gs://$BUCKET --member=serviceAccount:$UPLOAD_SA \
  --role=roles/storage.objectUser \
  --condition="expression=$(prefix downloads/),title=downloads-pointers"

# Promote: rewrite the appcasts and the downloads/ pointers. No access to releases/.
gcloud storage buckets add-iam-policy-binding gs://$BUCKET --member=serviceAccount:$PROMOTE_SA \
  --role=roles/storage.objectUser \
  --condition="expression=$(prefix appcast/),title=appcasts"
gcloud storage buckets add-iam-policy-binding gs://$BUCKET --member=serviceAccount:$PROMOTE_SA \
  --role=roles/storage.objectUser \
  --condition="expression=$(prefix downloads/),title=downloads-pointers"
```

Every read the scripts make goes through the public origin URL, so neither
account needs read rights on `releases/`. The workflows turn off gcloud's
parallel composite uploads, which would write temporary objects outside
`releases/` and then delete them.

**CDN invalidation** (`asdl-url-map`, `appcast.xml` and `downloads/*.json`):

```bash
gcloud iam roles create appStudioCdnInvalidator --project=$PROJECT \
  --title="App Studio CDN invalidator" \
  --permissions=compute.urlMaps.invalidateCache,compute.globalOperations.get
for sa in $UPLOAD_SA $PROMOTE_SA; do
  gcloud projects add-iam-policy-binding $PROJECT --member=serviceAccount:$sa \
    --role=projects/$PROJECT/roles/appStudioCdnInvalidator --condition=None
done
```

The scripts treat invalidation as best-effort. If it is missing, the log
shows a warning and the cache expires within its max-age.

### 6. GitHub variables

These are not secrets. They identify; they grant nothing on their own.

```bash
gh variable set GCP_WORKLOAD_IDENTITY_PROVIDER --repo $REPO \
  --body "projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/github/providers/appstudio"
gh variable set GCP_RELEASE_UPLOAD_SERVICE_ACCOUNT --repo $REPO --body $UPLOAD_SA
gh variable set GCP_RELEASE_PROMOTE_SERVICE_ACCOUNT --repo $REPO --body $PROMOTE_SA
```

### Where each secret lives

| Secret | Environment | What it is |
|---|---|---|
| `MACOS_DEVELOPER_ID_P12` | `release-upload` | base64 of the Developer ID Application `.p12` |
| `MACOS_DEVELOPER_ID_P12_PASSWORD` | `release-upload` | its export password |
| `APPLE_NOTARY_API_KEY_P8` | `release-upload` | the `AuthKey_*.p8` contents |
| `APPLE_NOTARY_API_KEY_ID` | `release-upload` | its Key ID |
| `APPLE_NOTARY_API_ISSUER_ID` | `release-upload` | the team's Issuer ID |
| `SPARKLE_ED25519_PRIVATE_KEY` | `production` | `generate_keys -x` output |
| `WINSPARKLE_ED25519_PRIVATE_KEY` | `production` | the WinSparkle key file |

## If something fails

- **`storage.buckets.get` denied on upload.** This version of gcloud reads
  bucket metadata before a copy. Grant both accounts a role with only that
  permission on the bucket.
- **The plan says "is not uploaded, but builds up to N already are".** The
  commit's build number is taken. Run `make set_version V=…`, or raise
  Windows's `build`, and push.
- **codesign: "unable to build chain" or "no identity found".** The `.p12` has
  no private key, or it is a different certificate type. The keychain step
  names the identity it expected.
- **Notarization `Invalid`.** The log of that submission is printed below the
  status, as with `make build`.
- **Promote: "the signing key does not match".** The secret is not the key the
  app ships. Do not change the shipped key to make it match: every installed
  copy has the old one.
