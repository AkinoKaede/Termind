import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "configure-firebase.sh"


class FirebaseConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.root = Path(self.temporary_directory.name)
        self.source = self.root / "Configuration/Firebase/GoogleService-Info.plist"
        self.bundled = self.root / "Products/Termind.app/Contents/Resources/GoogleService-Info.plist"
        self.upload_marker = self.root / "upload-arguments"
        uploader = self.root / "SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/run"
        uploader.parent.mkdir(parents=True)
        uploader.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$UPLOAD_MARKER"\n')
        uploader.chmod(0o700)
        self.environment = {
            **os.environ,
            "SRCROOT": str(self.root),
            "TARGET_BUILD_DIR": str(self.root / "Products"),
            "UNLOCALIZED_RESOURCES_FOLDER_PATH": "Termind.app/Contents/Resources",
            "BUILD_DIR": str(self.root / "Build/Products"),
            "UPLOAD_MARKER": str(self.upload_marker),
        }

    def write_configuration(self):
        self.source.parent.mkdir(parents=True)
        self.source.write_bytes(plistlib.dumps({"BUNDLE_ID": "com.example.test"}))

    def run_phase(self, configuration="Debug", upload="NO"):
        subprocess.run(
            ["/bin/sh", str(SCRIPT)],
            env={
                **self.environment,
                "CONFIGURATION": configuration,
                "FIREBASE_UPLOAD_SYMBOLS": upload,
            },
            check=True,
            capture_output=True,
            text=True,
        )

    def test_missing_configuration_neither_creates_a_plist_nor_uploads(self):
        self.run_phase(configuration="Release", upload="YES")
        self.assertFalse(self.bundled.exists())
        self.assertFalse(self.upload_marker.exists())

    def test_local_configuration_is_copied_without_uploading_by_default(self):
        self.write_configuration()
        self.run_phase(configuration="Release")
        self.assertEqual(self.bundled.read_bytes(), self.source.read_bytes())
        self.assertFalse(self.upload_marker.exists())

    def test_debug_never_uploads_even_when_enabled(self):
        self.write_configuration()
        self.run_phase(upload="YES")
        self.assertTrue(self.bundled.exists())
        self.assertFalse(self.upload_marker.exists())

    def test_release_uploads_the_bundled_configuration_only_when_enabled(self):
        self.write_configuration()
        self.run_phase(configuration="Release", upload="YES")
        self.assertEqual(self.upload_marker.read_text().splitlines(), ["-gsp", str(self.bundled)])

    def test_removing_local_configuration_clears_a_previous_build(self):
        self.write_configuration()
        self.run_phase()
        self.assertTrue(self.bundled.exists())
        self.source.unlink()
        self.run_phase(configuration="Release", upload="YES")
        self.assertFalse(self.bundled.exists())
        self.assertFalse(self.upload_marker.exists())


if __name__ == "__main__":
    unittest.main()
