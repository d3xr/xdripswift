"""Safety boundaries of the optional native rebuild helper; no toolchain downloads."""

import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("gs1_rebuild", Path(__file__).parents[1] / "rebuild.py")
REBUILD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REBUILD)


class RebuildSafetyTests(unittest.TestCase):
    def test_relative_source_metadata_is_allowed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "GS1Native").write_bytes(b"Source/SibionicsExactV115GCore.kt")
            REBUILD.verify_paths(root, [root])

    def test_absolute_build_metadata_is_rejected(self):
        for metadata in [b"/Users/build/Source/Core.kt", b"/home/build/Core.kt", b"/private/var/folders/cache/Core.kt"]:
            with self.subTest(metadata=metadata), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                (root / "GS1Native").write_bytes(metadata)
                with self.assertRaisesRegex(RuntimeError, "Build path found"):
                    REBUILD.verify_paths(root, [])

    def test_explicit_build_root_is_rejected_even_outside_common_home_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "GS1Native").write_bytes(b"/opt/gs1-build/Source/Core.kt")
            with self.assertRaisesRegex(RuntimeError, "Build path found"):
                REBUILD.verify_paths(root, [Path("/opt/gs1-build")])

    def test_existing_output_is_preserved_before_any_download_or_compiler(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "existing"
            output.mkdir()
            marker = output / "keep"
            marker.write_bytes(b"verified native artifact")
            with patch("sys.argv", ["rebuild.py", "--output", str(output)]), \
                 patch.object(REBUILD, "download_toolchains") as download, \
                 patch.object(REBUILD.subprocess, "run") as run, \
                 patch("sys.stderr", new_callable=io.StringIO):
                with self.assertRaises(SystemExit) as failure:
                    REBUILD.main()
            self.assertEqual(failure.exception.code, 2)
            download.assert_not_called()
            run.assert_not_called()
            self.assertEqual(marker.read_bytes(), b"verified native artifact")

    def test_untrusted_download_is_rejected_before_extracting(self):
        with tempfile.TemporaryDirectory() as tmp, \
             patch.object(REBUILD.urllib.request, "urlopen", return_value=io.BytesIO(b"wrong archive")), \
             patch.object(REBUILD.subprocess, "run") as run, \
             patch("sys.stdout", new_callable=io.StringIO):
            with self.assertRaisesRegex(RuntimeError, "Unexpected SHA-256"):
                REBUILD.download_toolchains(Path(tmp))
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
