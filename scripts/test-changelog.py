"""Changelog rotation checks; pure text, no git or files outside a temporary directory."""
import datetime
import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('changelog', Path(__file__).with_name('changelog.py'))
changelog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(changelog)

SAMPLE = """# Changelog

Intro paragraph with a [link](https://example.com) that must stay.

## [Unreleased]

### Fixed

- A fix.

## [1.0.0] - 2026-10-31

First release.

[Unreleased]: https://github.com/DPostnik/Switchboard/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/DPostnik/Switchboard/releases/tag/v1.0.0
"""


class ChangelogTests(unittest.TestCase):
    def test_rotate_moves_unreleased_into_the_new_version_and_updates_links(self):
        result = changelog.rotate(SAMPLE, '1.1.0', today=datetime.date(2026, 11, 5))
        self.assertEqual(result, """# Changelog

Intro paragraph with a [link](https://example.com) that must stay.

## [Unreleased]

## [1.1.0] - 2026-11-05

### Fixed

- A fix.

## [1.0.0] - 2026-10-31

First release.

[Unreleased]: https://github.com/DPostnik/Switchboard/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/DPostnik/Switchboard/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/DPostnik/Switchboard/releases/tag/v1.0.0
""")
        self.assertEqual(changelog.unreleased(result), '')
        self.assertEqual(changelog.unreleased(SAMPLE), '### Fixed\n\n- A fix.')

    def test_first_release_links_to_the_tag(self):
        text = "# Changelog\n\n## [Unreleased]\n\n- Everything.\n"
        result = changelog.rotate(text, '1.0.0', today=datetime.date(2026, 10, 31))
        self.assertIn('## [1.0.0] - 2026-10-31\n\n- Everything.\n', result)
        self.assertTrue(result.endswith('[1.0.0]: https://github.com/DPostnik/Switchboard/releases/tag/v1.0.0\n'))

    def test_refuses_empty_unreleased_bad_versions_and_duplicates(self):
        rotated = changelog.rotate(SAMPLE, '1.1.0', today=datetime.date(2026, 11, 5))
        with self.assertRaises(changelog.ChangelogError):
            changelog.rotate(rotated, '1.2.0')
        with self.assertRaises(changelog.ChangelogError):
            changelog.rotate(SAMPLE, '1.0.0')
        with self.assertRaises(changelog.ChangelogError):
            changelog.rotate(SAMPLE, 'v1.1')
        with self.assertRaises(changelog.ChangelogError):
            changelog.rotate("# No sections\n", '1.1.0')

    def test_cli_print_does_not_write(self):
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'CHANGELOG.md'
            path.write_text(SAMPLE)
            self.assertEqual(changelog.main(['rotate', '1.1.0', '--path', str(path), '--print']), 0)
            self.assertEqual(path.read_text(), SAMPLE)
            self.assertEqual(changelog.main(['rotate', '1.1.0', '--path', str(path)]), 0)
            self.assertIn('## [1.1.0] - ', path.read_text())
            self.assertEqual(changelog.main(['unreleased', '--path', str(path)]), 1)


if __name__ == '__main__':
    unittest.main()
