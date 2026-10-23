"""Bootstrap must not overwrite existing identities or ask for secrets first."""
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
TEMP = ROOT/'build/test-temp'
TEMP.mkdir(parents=True, exist_ok=True)
spec = importlib.util.spec_from_file_location('configure_bot', ROOT/'tools/configure_bot.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class BootstrapTests(unittest.TestCase):
    def run_with(self, source, data):
        with patch.object(sys, 'argv', ['configure_bot', '--deployment', str(source), '--data', str(data)]):
            module.main()

    def test_existing_plugin_preserved_before_any_prompt_or_write(self):
        with tempfile.TemporaryDirectory(dir=TEMP) as folder:
            data = Path(folder)/'data'
            plugin = data/'plugins/astrbot_plugin_subtitle_notify'
            plugin.mkdir(parents=True)
            sentinel = plugin/'main.py'
            sentinel.write_text('existing version', encoding='utf8')
            with patch('builtins.input', side_effect=AssertionError('unexpected prompt')):
                with self.assertRaises(SystemExit): self.run_with(Path(folder)/'missing', data)
            self.assertEqual(sentinel.read_text(encoding='utf8'), 'existing version')
            self.assertFalse((data/'subtitle_bridge.json').exists())

    def test_incomplete_source_creates_no_config_directory(self):
        with tempfile.TemporaryDirectory(dir=TEMP) as folder:
            data = Path(folder)/'data'
            with patch('builtins.input', side_effect=AssertionError('unexpected prompt')):
                with self.assertRaises(SystemExit): self.run_with(Path(folder)/'missing', data)
            self.assertFalse(data.exists())

    def test_existing_notification_state_is_preserved(self):
        with tempfile.TemporaryDirectory(dir=TEMP) as folder:
            data = Path(folder)/'data'
            data.mkdir()
            state = data/'subtitle_notifications.json'
            state.write_text('{"enabled":true}', encoding='utf8')
            with self.assertRaises(SystemExit): self.run_with(Path(folder)/'missing', data)
            self.assertEqual(state.read_text(encoding='utf8'), '{"enabled":true}')
            self.assertFalse((data/'subtitle_bridge.json').exists())

if __name__ == '__main__': unittest.main()
