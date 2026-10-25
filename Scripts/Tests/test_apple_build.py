# SPDX-FileCopyrightText: 2026 Kaede Akino
# SPDX-License-Identifier: GPL-3.0-only

import base64
import datetime
import importlib.util
import io
import itertools
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET
import zipfile


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("apple_build", ROOT / "Scripts/ci/apple-build.py")
CI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CI)
PROFILE_ID = "01234567-89ab-cdef-0123-456789abcdef"


def encoded(data):
    return base64.b64encode(data).decode()


def profile_zip(entries=None):
    data = io.BytesIO()
    with zipfile.ZipFile(data, "w") as archive:
        for name, value in (entries or {"development.provisionprofile": b"signed-profile"}).items():
            archive.writestr(name, value)
    return data.getvalue()


def environment():
    return {
        "FIREBASE_CONFIG_BASE64": encoded(plistlib.dumps({
            "BUNDLE_ID": CI.BUNDLE_ID,
            "GOOGLE_APP_ID": "1:123:ios:fixture",
            "API_KEY": "firebase-fixture",
            "PROJECT_ID": "fixture-project",
            "GCM_SENDER_ID": "123",
        })),
        "REVENUECAT_API_KEY": "appl_fixture",
        "REVENUECAT_ENTITLEMENT_ID": "termind_pro",
        "APPLE_CERTIFICATES_P12_BASE64": encoded(b"certificate-fixture"),
        "APPLE_CERTIFICATES_PASSWORD": "fixture-password",
        "APPLE_PROVISIONING_PROFILES_BASE64": encoded(profile_zip()),
        "ASC_KEY_BASE64": encoded(b"-----BEGIN PRIVATE KEY-----\nfixture\n-----END PRIVATE KEY-----"),
        "ASC_KEY_ID": "ABC123DE45",
        "ASC_ISSUER_ID": "12345678-1234-1234-1234-123456789abc",
    }


class AppleBuildInputsTests(unittest.TestCase):
    def test_all_selects_both_platforms_and_single_platform_does_not_build_the_other(self):
        self.assertEqual(CI.build_matrix("1.17.4", "All")["include"], [{"platform": "iOS"}, {"platform": "macOS"}])
        for platform in CI.PLATFORMS:
            self.assertEqual(CI.build_matrix("1.17.4", platform)["include"], [{"platform": platform}])

    def test_versions_require_three_numeric_components_and_platforms_are_closed(self):
        for version in ("", "1.2", "v1.2.3", "1.2.3-beta", "1.2.3\nINJECTED=true", "$(touch bad)", "patch"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                CI.build_matrix(version, "All")
        with self.assertRaises(ValueError):
            CI.build_matrix("1.2.3", "Linux")

    @patch.object(CI, "mask")
    def test_service_config_uses_shared_firebase_and_enables_release_symbols(self, mask):
        firebase, xcconfig = CI.service_configuration(environment())
        self.assertEqual(plistlib.loads(firebase)["BUNDLE_ID"], CI.BUNDLE_ID)
        self.assertIn(b"REVENUECAT_API_KEY = appl_fixture", xcconfig)
        self.assertIn(b"FIREBASE_UPLOAD_SYMBOLS = YES", xcconfig)
        mask.assert_any_call("firebase-fixture")
        mask.assert_any_call("appl_fixture")

    @patch.object(CI, "mask")
    def test_missing_or_invalid_service_config_fails_without_exposing_values(self, _):
        for name in ("FIREBASE_CONFIG_BASE64", "REVENUECAT_API_KEY", "REVENUECAT_ENTITLEMENT_ID"):
            config = environment()
            del config[name]
            with self.subTest(name=name), self.assertRaises(ValueError):
                CI.service_configuration(config)
        for name, value in (("REVENUECAT_API_KEY", "sk_private_fixture"),
                            ("REVENUECAT_ENTITLEMENT_ID", "secret\n#include other"),
                            ("FIREBASE_CONFIG_BASE64", encoded(b"not a plist"))):
            with self.subTest(name=name), self.assertRaises(ValueError) as error:
                CI.service_configuration({**environment(), name: value})
            self.assertNotIn(value, str(error.exception))
        config = environment()
        config["FIREBASE_CONFIG_BASE64"] = encoded(plistlib.dumps({"BUNDLE_ID": "com.other.app"}))
        with self.assertRaisesRegex(ValueError, "BUNDLE_ID"):
            CI.service_configuration(config)

    def test_profiles_are_read_as_data_without_extracting_supplied_paths(self):
        self.assertEqual(CI.profile_payloads(profile_zip({"../../escape.mobileprovision": b"data"})),
                         [(".mobileprovision", b"data")])
        with self.assertRaises(ValueError):
            CI.profile_payloads(profile_zip({"helper.py": b"code"}))

    def test_macos_development_profile_without_debug_flag_is_not_confused_with_distribution(self):
        mac = {"Platform": ["OSX"], "ProvisionedDevices": ["registered-mac"], "Entitlements": {}}
        self.assertTrue(CI.is_development_profile(mac))
        self.assertFalse(CI.is_development_profile({**mac, "ProvisionedDevices": []}))
        self.assertFalse(CI.is_development_profile({**mac, "ProvisionsAllDevices": True}))
        self.assertFalse(CI.is_development_profile({**mac, "Entitlements": {"get-task-allow": False}}))
        self.assertFalse(CI.is_development_profile({**mac, "Platform": ["iOS"]}))

    def test_export_uploads_to_connect_without_internal_only_restriction(self):
        options = CI.export_options("F6SUNDBBN9")
        self.assertEqual(options["method"], "app-store-connect")
        self.assertEqual(options["destination"], "upload")
        self.assertTrue(options["manageAppVersionAndBuildNumber"])
        self.assertEqual(options["iCloudContainerEnvironment"], "Production")
        self.assertNotIn("testFlightInternalTestingOnly", options)


class AppleSigningEnvironmentTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.directory = self.root / "private"
        self.directory.mkdir()
        self.home = self.root / "home"
        self.profiles = self.home / "Library/Developer/Xcode/UserData/Provisioning Profiles"
        self.profiles.mkdir(parents=True)
        self.old_profile = self.profiles / (PROFILE_ID + ".provisionprofile")
        self.old_profile.write_bytes(b"original-profile")
        project = self.root / "Termind.xcodeproj/project.pbxproj"
        project.parent.mkdir()
        project.write_text("DEVELOPMENT_TEAM = F6SUNDBBN9;\n")
        self.service = self.root / "Configuration/Services.local.xcconfig"
        self.service.parent.mkdir()
        self.service.write_text("original-service")
        self.service.chmod(0o640)
        self.calls = []
        self.fail_on = None
        self.team = "F6SUNDBBN9"
        self.entitlements = {"get-task-allow": True, "com.apple.developer.icloud-container-environment": ["Development"]}
        self.security = patch.object(CI, "security", side_effect=self.fake_security)
        self.security.start()
        self.addCleanup(self.security.stop)
        self.mask = patch.object(CI, "mask")
        self.mask.start()
        self.addCleanup(self.mask.stop)

    def fake_security(self, *arguments):
        self.calls.append(arguments)
        if arguments[0] == self.fail_on:
            raise RuntimeError("simulated security failure")
        if arguments == ("list-keychains", "-d", "user"):
            return b'    "/original/login.keychain-db"\n    "/original/with spaces.keychain-db"\n'
        if arguments[0] == "create-keychain":
            Path(arguments[-1]).write_bytes(b"keychain")
        if arguments[0] == "delete-keychain":
            Path(arguments[-1]).unlink()
        if arguments[0] == "cms":
            return plistlib.dumps({
                "UUID": PROFILE_ID, "TeamIdentifier": [self.team],
                "ExpirationDate": datetime.datetime.now() + datetime.timedelta(days=30),
                "Entitlements": self.entitlements,
            })
        return b""

    def prepare(self, config=None):
        CI.prepare(self.root, self.directory, self.home, config or environment())

    def assert_restored(self):
        self.assertEqual(self.old_profile.read_bytes(), b"original-profile")
        self.assertEqual(self.service.read_text(), "original-service")
        self.assertEqual(self.service.stat().st_mode & 0o777, 0o640)
        self.assertFalse((self.root / "Configuration/Firebase/GoogleService-Info.plist").exists())
        self.assertFalse(self.directory.exists())

    def test_setup_and_cleanup_preserve_existing_keychains_profiles_and_local_config(self):
        self.prepare()
        self.assertEqual(self.old_profile.read_bytes(), b"signed-profile")
        self.assertEqual((self.directory / "AuthKey.p8").stat().st_mode & 0o777, 0o600)
        downloaded = self.profiles / "downloaded.mobileprovision"
        downloaded.write_bytes(b"downloaded-by-xcode")
        CI.cleanup(self.directory)
        self.assert_restored()
        self.assertFalse(downloaded.exists())
        self.assertIn(("list-keychains", "-d", "user", "-s", "/original/login.keychain-db",
                       "/original/with spaces.keychain-db"), self.calls)

    def test_cleanup_after_partial_certificate_import_failure(self):
        self.fail_on = "import"
        with self.assertRaises(RuntimeError):
            self.prepare()
        self.fail_on = None
        CI.cleanup(self.directory)
        self.assert_restored()

    def test_missing_credentials_does_not_mutate_runner(self):
        config = environment()
        del config["ASC_KEY_BASE64"]
        with self.assertRaises(ValueError):
            self.prepare(config)
        self.assertEqual(self.calls, [])
        self.assertEqual(self.service.read_text(), "original-service")
        CI.cleanup(self.directory)
        self.assert_restored()

    def test_cleanup_failure_is_reported_and_can_be_retried(self):
        self.prepare()
        self.fail_on = "delete-keychain"
        with self.assertRaisesRegex(RuntimeError, "simulated security failure"):
            CI.cleanup(self.directory)
        self.assertTrue((self.directory / "state.json").exists())
        self.assertEqual(self.service.read_text(), "original-service")
        self.fail_on = None
        CI.cleanup(self.directory)
        self.assert_restored()

    def development_environment(self):
        return {
            "APPLE_DEVELOPMENT_CERTIFICATES_P12_BASE64": encoded(b"development-certificate"),
            "APPLE_DEVELOPMENT_CERTIFICATES_PASSWORD": "development-password",
            "APPLE_DEVELOPMENT_PROFILES_BASE64": encoded(profile_zip()),
        }

    def test_development_needs_only_development_secrets_and_restores_existing_services(self):
        firebase = self.root / "Configuration/Firebase/GoogleService-Info.plist"
        firebase.parent.mkdir()
        firebase.write_bytes(b"original-firebase")
        CI.prepare(self.root, self.directory, self.home, self.development_environment(), development=True)
        self.assertFalse(firebase.exists())
        self.assertIn("REVENUECAT_API_KEY =\n", self.service.read_text())
        self.assertIn("FIREBASE_UPLOAD_SYMBOLS = NO", self.service.read_text())
        for filename in ("AuthKey.p8", "authentication.json", "ExportOptions.plist"):
            self.assertFalse((self.directory / filename).exists())
        CI.cleanup(self.directory)
        self.assertEqual(firebase.read_bytes(), b"original-firebase")
        firebase.unlink()
        self.assert_restored()

    def test_development_does_not_fall_back_to_release_credentials(self):
        with self.assertRaisesRegex(ValueError, "APPLE_DEVELOPMENT_CERTIFICATES_P12_BASE64"):
            CI.prepare(self.root, self.directory, self.home, environment(), development=True)
        self.assertEqual(self.calls, [])
        CI.cleanup(self.directory)
        self.assert_restored()

    def test_development_rejects_distribution_profiles_and_restores_state(self):
        self.entitlements = {"get-task-allow": False}
        with self.assertRaisesRegex(ValueError, "not distribution profiles"):
            CI.prepare(self.root, self.directory, self.home, self.development_environment(), development=True)
        CI.cleanup(self.directory)
        self.assert_restored()

    def test_development_rejects_production_only_cloudkit_profiles(self):
        self.entitlements["com.apple.developer.icloud-container-environment"] = ["Production"]
        with self.assertRaisesRegex(ValueError, "Development CloudKit"):
            CI.prepare(self.root, self.directory, self.home, self.development_environment(), development=True)
        CI.cleanup(self.directory)
        self.assert_restored()

    def test_development_accepts_macos_debug_entitlement(self):
        self.entitlements = {"com.apple.security.get-task-allow": True}
        CI.prepare(self.root, self.directory, self.home, self.development_environment(), development=True)
        CI.cleanup(self.directory)
        self.assert_restored()

    def test_profile_from_wrong_team_is_rejected_and_cleanup_restores_runner(self):
        self.team = "OTHERTEAM1"
        with self.assertRaisesRegex(ValueError, "different Apple team"):
            self.prepare()
        CI.cleanup(self.directory)
        self.assert_restored()


class AdHocWorkflowTests(unittest.TestCase):
    def test_both_platform_schemes_run_application_and_framework_tests(self):
        for scheme, application_tests in (("TFM", "TFMTests"), ("TFI", "TFITests")):
            with self.subTest(scheme=scheme):
                path = ROOT / f"Termind.xcodeproj/xcshareddata/xcschemes/{scheme}.xcscheme"
                testables = ET.parse(path).findall("./TestAction/Testables/TestableReference")
                enabled = {
                    reference.find("BuildableReference").get("BlueprintName")
                    for reference in testables if reference.get("skipped") == "NO"
                }
                self.assertIn(application_tests, enabled)
                self.assertIn("FrameworkTests", enabled)

    def test_native_tests_run_on_prs_without_environment_or_secrets(self):
        workflow = (ROOT / ".github/workflows/test.yml").read_text()
        native = workflow.split("  test:\n", 1)[1]
        self.assertIn("  pull_request:\n", workflow)
        self.assertNotRegex(workflow, r"\$\{\{[^}\n]*\bsecrets\s*[.\[]")
        self.assertNotIn("environment:", workflow)
        self.assertNotIn("pull_request_target", workflow)
        self.assertNotRegex(native, r"(?m)^    if:")
        self.assertNotIn("prepare-development", workflow)
        self.assertIn("persist-credentials: false", native)

    def test_ad_hoc_tests_disable_real_service_integration(self):
        workflow = (ROOT / ".github/workflows/test.yml").read_text()
        for setting in ("-configuration Debug", "CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual",
                        "DEVELOPMENT_TEAM=", "CODE_SIGN_ENTITLEMENTS=", "ENABLE_APP_SANDBOX=NO"):
            self.assertIn(setting, workflow)
        self.assertIn('TEST_RUNNER_TERMIND_SIGNED_INTEGRATION_TESTS: "0"', workflow)
        self.assertNotIn("-allowProvisioningUpdates", workflow)
        self.assertNotIn("security import", workflow)
        artifact_step = workflow.split("      - name: Upload test results\n", 1)[1]
        self.assertEqual(re.search(r"^          path: (.+)$", artifact_step, re.MULTILINE).group(1),
                         "${{ runner.temp }}/test-results/")


class SwiftPackageCacheTests(unittest.TestCase):
    def test_workflows_share_only_package_cache_with_toolchain_and_lockfile_keys(self):
        keys = []
        for filename in ("test.yml", "build.yml"):
            with self.subTest(workflow=filename):
                workflow = (ROOT / ".github/workflows" / filename).read_text()
                self.assertIn('echo "SPM_CACHE_DIR=$RUNNER_TEMP/DerivedData/SourcePackages" >> "$GITHUB_ENV"', workflow)
                restore = workflow.split("      - name: Restore Swift packages\n", 1)[1].split("\n      - name:", 1)[0]
                save = workflow.split("      - name: Save Swift packages\n", 1)[1].split("\n      - name:", 1)[0]
                self.assertIn("uses: actions/cache/restore@", restore)
                self.assertIn("uses: actions/cache/save@", save)
                for step in (restore, save):
                    self.assertEqual(re.findall(r"^          path: (.+)$", step, re.MULTILINE),
                                     ["${{ env.SPM_CACHE_DIR }}"])
                key = re.search(r"^          key: (.+)$", restore, re.MULTILINE).group(1)
                for component in ("runner.os", "runner.arch", "steps.toolchain.outputs.cache-key",
                                  "hashFiles('Termind.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved')"):
                    self.assertIn(component, key)
                self.assertIn("xcodebuild -version | shasum -a 256", workflow)
                self.assertIn("key: ${{ steps.spm-cache.outputs.cache-primary-key }}", save)
                self.assertEqual(re.search(r"^        if: (.+)$", save, re.MULTILINE).group(1),
                                 "${{ steps.spm-cache.outputs.cache-hit != 'true' }}")
                execution = "Run tests" if filename == "test.yml" else "Archive and upload to App Store Connect"
                self.assertLess(workflow.index("name: Restore Swift packages"), workflow.index(f"name: {execution}"))
                self.assertLess(workflow.index(f"name: {execution}"), workflow.index("name: Save Swift packages"))
                keys.append(key)
        self.assertEqual(keys[0], keys[1])

    def test_test_job_uses_cached_packages_without_caching_test_results(self):
        workflow = (ROOT / ".github/workflows/test.yml").read_text()
        self.assertIn('-clonedSourcePackagesDirPath "$SPM_CACHE_DIR"', workflow)
        self.assertIn('-derivedDataPath "$RUNNER_TEMP/DerivedData"', workflow)


class AppleArchiveTests(unittest.TestCase):
    def test_both_platforms_archive_then_upload_with_pinned_packages_and_matching_widget_version(self):
        platforms = (("iOS", "TFI", "generic/platform=iOS"), ("macOS", "TFM", "generic/platform=macOS"))
        for (platform, scheme, destination), cached in itertools.product(platforms, (False, True)):
            with self.subTest(platform=platform, cached=cached), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                for relative in ("Scripts/ci/archive-apple.sh", "Scripts/bump-version.py",
                                 "Termind.xcodeproj/project.pbxproj"):
                    target = root / relative
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(ROOT / relative, target)
                private = root / "private"
                private.mkdir()
                (private / "authentication.json").write_text(json.dumps({"key_id": "fixture", "issuer": "fixture"}))
                binary = root / "bin"
                binary.mkdir()
                stub = binary / "xcodebuild"
                stub.write_text(
                    "#!/usr/bin/env python3\nimport json, os, sys\n"
                    "with open(os.environ['COMMAND_LOG'], 'a') as output:\n"
                    "    output.write(json.dumps(sys.argv[1:]) + '\\n')\n"
                )
                stub.chmod(0o700)
                log = root / "commands.jsonl"
                packages = root / "SourcePackages" if cached else private / "DerivedData/SourcePackages"
                crashlytics = packages / "checkouts/firebase-ios-sdk/Crashlytics/run"
                crashlytics.parent.mkdir(parents=True)
                crashlytics.write_text("fixture Crashlytics script")
                environment = {**os.environ, "PATH": str(binary) + os.pathsep + os.environ["PATH"],
                               "APPLE_CI_DIR": str(private), "BUILD_PLATFORM": platform,
                               "BUILD_VERSION": "2.3.4", "COMMAND_LOG": str(log),
                               "GITHUB_STEP_SUMMARY": str(root / "summary.md")}
                environment.pop("SPM_CACHE_DIR", None)
                if cached:
                    environment["SPM_CACHE_DIR"] = str(packages)
                subprocess.run(["bash", str(root / "Scripts/ci/archive-apple.sh")], check=True, capture_output=True,
                               env=environment)
                archive, upload = [json.loads(line) for line in log.read_text().splitlines()]
                self.assertEqual(archive[archive.index("-clonedSourcePackagesDirPath") + 1], str(packages))
                firebase_lookup = private / "DerivedData/SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/run"
                self.assertEqual(firebase_lookup.resolve(), crashlytics.resolve())
                self.assertTrue(firebase_lookup.is_file())
                self.assertEqual(archive[archive.index("-scheme") + 1], scheme)
                self.assertEqual(archive[archive.index("-destination") + 1], destination)
                self.assertIn("-onlyUsePackageVersionsFromResolvedFile", archive)
                self.assertEqual(archive[-1], "archive")
                self.assertIn("-exportArchive", upload)
                for command in (archive, upload):
                    self.assertIn("-authenticationKeyIssuerID", command)
                    self.assertNotIn("CODE_SIGN_ENTITLEMENTS=", command)
                version = CI.version_module()
                text = (root / "Termind.xcodeproj/project.pbxproj").read_text()
                states = {scope.name: version.read_state(text, scope) for scope in version.SCOPES}
                self.assertTrue(all(state.marketing_version == "2.3.4" for state in states.values()))
                self.assertEqual(states["TFI"], states["Widgets"])

                # An archive failure must propagate without uploading or writing a success summary.
                log.unlink()
                (root / "summary.md").unlink()
                stub.write_text(stub.read_text() + "sys.exit(65)\n")
                failed = subprocess.run(
                    ["bash", str(root / "Scripts/ci/archive-apple.sh")], capture_output=True,
                    env=environment)
                self.assertEqual(failed.returncode, 65)
                self.assertEqual(len(log.read_text().splitlines()), 1)
                self.assertFalse((root / "summary.md").exists())
                CI.cleanup(private)
                self.assertFalse(private.exists())
                self.assertEqual(crashlytics.exists(), cached)


if __name__ == "__main__":
    unittest.main()
