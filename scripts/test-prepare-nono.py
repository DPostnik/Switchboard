#!/usr/bin/env python3
"""Cheap packaging rejection checks; no compiler or network."""
import importlib.util
import pathlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('prepare_nono', pathlib.Path(__file__).with_name('prepare-nono.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class PackagingTests(unittest.TestCase):
    def test_bad_archive_never_extracts_or_launches(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            archive = root / 'bad.tar.gz'
            archive.write_bytes(b'not a release')
            with patch.object(module.tarfile, 'open') as extract, patch.object(module.subprocess, 'run') as run:
                with self.assertRaisesRegex(ValueError, 'archive checksum'):
                    module.prepare(root / 'bundle', archive)
                extract.assert_not_called()
                run.assert_not_called()
                self.assertFalse((root / 'bundle/nono').exists())

    def test_modified_binary_never_runs(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = pathlib.Path(directory) / 'nono'
            binary.write_bytes(b'changed binary')
            with patch.object(module.subprocess, 'check_output') as launch:
                with self.assertRaisesRegex(ValueError, 'binary checksum'):
                    module.verify(binary)
                launch.assert_not_called()

    def test_wrong_architecture_rejected(self):
        with patch.object(module, 'digest', return_value=module.LOCK['binary_sha256']), \
             patch.object(module.subprocess, 'check_output', return_value='x86_64\n'), \
             patch.object(module.subprocess, 'run') as sign:
            with self.assertRaisesRegex(ValueError, 'architecture'):
                module.verify(pathlib.Path('unused'))
            sign.assert_not_called()

    def test_signature_checks_vendor_identity(self):
        with patch.object(module, 'digest', return_value=module.LOCK['binary_sha256']), \
             patch.object(module.subprocess, 'check_output', return_value='arm64\n'), \
             patch.object(module.subprocess, 'run') as sign:
            module.verify(pathlib.Path('unused'))
            command = sign.call_args.args[0]
            self.assertIn('--strict', command)
            self.assertIn(module.LOCK['team_identifier'], command[-2])
            self.assertIn(module.LOCK['identifier'], command[-2])
            self.assertTrue(sign.call_args.kwargs['check'])

if __name__ == '__main__':
    unittest.main()
