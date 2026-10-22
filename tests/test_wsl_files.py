import importlib.util
import io
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('wsl_files', ROOT / 'skills/wezterm-wsl/scripts/wsl-files.py')
FILES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FILES)


class FileOperations(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="wsl files 中文 ' ")
        self.root = Path(self.temporary.name)
        self.path = self.root / "it's 中文.txt"

    def tearDown(self):
        self.temporary.cleanup()

    def call(self, op, path=None, **fields):
        return FILES.execute(dict(op=op, path=str(path or self.path), **fields))

    def error(self, code, op, **fields):
        with self.assertRaises(FILES.FileError) as raised:
            self.call(op, **fields)
        self.assertEqual(raised.exception.code, code)

    def test_create_unicode_and_empty(self):
        result = self.call('write', content='中文\r\n$HOME\r\n')
        self.assertEqual(self.path.read_bytes(), '中文\n$HOME\n'.encode())
        self.assertEqual(self.call('read')['sha256'], result['sha256'])
        self.assertEqual(self.path.stat().st_mode & 0o111, 0)
        self.call('write', content='', expected_hash=result['sha256'])
        self.assertEqual(self.path.read_bytes(), b'')

    def test_write_refuses_overwrite_and_stale_hash(self):
        self.call('write', content='original')
        self.error('exists', 'write', content='lost')
        self.error('conflict', 'write', content='lost', expected_hash='0' * 64)
        self.assertEqual(self.path.read_text(), 'original')
        self.call('write', content='explicit', overwrite=True)
        self.assertEqual(self.path.read_text(), 'explicit')

    def test_boolean_string_cannot_enable_overwrite(self):
        self.call('write', content='original')
        self.error('invalid_request', 'write', content='lost', overwrite='false')
        self.assertEqual(self.path.read_text(), 'original')

    def test_edit_preserves_mode_crlf_and_xattrs(self):
        self.path.write_bytes(b'first\r\nsecond\r\n')
        self.path.chmod(0o640)
        os.setxattr(self.path, 'user.wezterm_test', b'value')
        before = self.call('read')['sha256']
        self.call('edit', old='first\nsecond', new='one\ntwo', expected_hash=before)
        self.assertEqual(self.path.read_bytes(), b'one\r\ntwo\r\n')
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o640)
        self.assertEqual(os.getxattr(self.path, 'user.wezterm_test'), b'value')

    def test_ambiguous_and_missing_edit_do_not_write(self):
        self.call('write', content='same same')
        self.error('match_count', 'edit', old='same', new='other')
        self.error('match_count', 'edit', old='absent', new='other')
        self.assertEqual(self.path.read_text(), 'same same')
        result = self.call('edit', old='same', new='', all=True)
        self.assertEqual(result['replacements'], 2)
        self.assertEqual(self.path.read_text(), ' ')

    def test_changed_file_before_commit_is_rejected(self):
        self.path.write_text('before')
        data, _, info = FILES.load_text(self.path)
        self.path.write_text('concurrent')
        with self.assertRaises(FILES.FileError) as raised:
            FILES.replace_text(self.path, b'after', data, info)
        self.assertEqual(raised.exception.code, 'conflict')
        self.assertEqual(self.path.read_text(), 'concurrent')
        self.assertEqual(len(list(self.root.iterdir())), 1)

    def test_read_range_and_bounds(self):
        self.path.write_text('one\ntwo\nthree\n')
        result = self.call('read', **{'from': 2, 'lines': 1})
        self.assertEqual(result['content'], 'two\n')
        self.assertTrue(result['truncated'])
        self.path.write_text('中' * 200)
        self.assertEqual(len(self.call('read', max_chars=128)['content']), 128)

    def test_list_limits_hidden_files_and_links(self):
        (self.root / '.hidden').touch()
        (self.root / 'directory').mkdir()
        (self.root / 'file').touch()
        (self.root / 'link').symlink_to(self.root / 'file')
        limited = self.call('ls', self.root, limit=1)
        self.assertEqual(limited['omitted'], 2)
        entries = self.call('ls', self.root, all=True)['entries']
        self.assertEqual({entry['name']: entry['type'] for entry in entries},
                         {'.hidden': 'file', 'directory': 'dir', 'file': 'file', 'link': 'link'})

    def test_move_no_clobber_and_explicit_overwrite(self):
        self.path.write_text('source')
        self.path.chmod(0o640)
        destination = self.root / 'destination.txt'
        destination.write_text('destination')
        self.error('exists', 'mv', to=str(destination))
        self.assertEqual(self.path.read_text(), 'source')
        self.assertEqual(destination.read_text(), 'destination')
        self.call('mv', to=str(destination), overwrite=True)
        self.assertFalse(self.path.exists())
        self.assertEqual(destination.read_text(), 'source')
        self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o640)

    def test_move_directory_and_create_parents(self):
        self.path.mkdir()
        (self.path / 'file').write_text('contents')
        destination = self.root / 'new/sub/directory'
        self.call('mv', to=str(destination), parents=True)
        self.assertEqual((destination / 'file').read_text(), 'contents')

    def test_symlink_and_hardlink_writes_refused(self):
        target = self.root / 'target'
        target.write_text('safe')
        self.path.symlink_to(target)
        self.error('symlink', 'write', content='lost', overwrite=True)
        self.path.unlink()
        os.link(target, self.path)
        self.error('special_file', 'edit', old='safe', new='lost')
        self.assertEqual(target.read_text(), 'safe')

    def test_binary_invalid_encoding_and_large_file_refused(self):
        self.path.write_bytes(b'a\0b')
        self.error('binary_file', 'read')
        self.path.write_bytes(b'\xff')
        self.error('encoding', 'read')
        with self.path.open('wb') as stream:
            stream.truncate(FILES.MAX_BYTES + 1)
        self.error('too_large', 'read')



class SearchOperations(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="wsl search 中文 ' ")
        self.root = Path(self.temporary.name)
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        (self.root / 'src').mkdir()
        (self.root / 'src/app.py').write_text('first\nHello 中文\nhello.world\n')
        (self.root / 'main.py').write_text('helloXworld\n')
        (self.root / '.hidden.py').write_text('hidden needle\n')
        (self.root / 'ignored.py').write_text('ignored needle\n')
        (self.root / '.gitignore').write_text('ignored.py\n')
        (self.root / 'binary').write_bytes(b'\0needle\0')

    def tearDown(self):
        self.temporary.cleanup()

    def call(self, op, pattern, **fields):
        return FILES.execute(dict(op=op, path=str(self.root), pattern=pattern, **fields))

    def test_regex_case_literal_and_file_scope(self):
        result = self.call('grep', '^hello', ignore_case=True, glob='src/*.py')
        self.assertEqual([(m['path'], m['line']) for m in result['matches']], [('src/app.py', 2), ('src/app.py', 3)])
        self.assertEqual(result['matches'][0]['text'], 'Hello 中文')
        self.assertFalse(result['truncated'])
        self.assertEqual(len(self.call('grep', 'hello.world')['matches']), 2)
        self.assertEqual(len(self.call('grep', 'hello.world', literal=True)['matches']), 1)
        result = FILES.execute(dict(op='grep', path=str(self.root / 'src/app.py'), pattern='Hello'))
        self.assertEqual(result['matches'][0]['path'], 'app.py')

    def test_default_ignore_binary_and_all(self):
        self.assertEqual(self.call('grep', 'needle')['matches'], [])
        (self.root / '.git/private').write_text('needle')
        result = self.call('grep', 'needle', all=True)
        self.assertEqual([m['path'] for m in result['matches']], ['.hidden.py', 'ignored.py'])

    def test_glob_recursive_exclusions_and_explicit_inclusion(self):
        result = self.call('glob', '**/*.py', glob=['!ignored.py', '!.hidden.py'])
        self.assertEqual(result['paths'], ['main.py', 'src/app.py'])
        # Native rg positive globs explicitly override hidden/ignore filters.
        self.assertIn('ignored.py', self.call('glob', '*.py')['paths'])
        self.assertEqual(self.call('glob', 'src/*.py')['paths'], ['src/app.py'])

    def test_no_matches_are_success(self):
        for op, field in [('grep', 'matches'), ('glob', 'paths')]:
            result = self.call(op, 'DOES_NOT_EXIST')
            self.assertEqual(result[field], [])
            self.assertFalse(result['truncated'])

    def test_invalid_regex_missing_path_and_request(self):
        for request, code in [
            (dict(op='grep', path=str(self.root), pattern='['), 'search_failed'),
            (dict(op='grep', path=str(self.root / 'missing'), pattern='x'), 'not_found'),
            (dict(op='glob', path=str(self.root / 'main.py'), pattern='*'), 'invalid_request'),
            (dict(op='grep', path=str(self.root), pattern='x', ignore_case='false'), 'invalid_request'),
            (dict(op='grep', path=str(self.root), pattern='x', glob=[123]), 'invalid_request'),
            (dict(op='grep', path=str(self.root), pattern='x\ny'), 'invalid_request'),
        ]:
            with self.subTest(request=request), self.assertRaises(FILES.FileError) as raised:
                FILES.execute(request)
            self.assertEqual(raised.exception.code, code)

    def test_global_result_and_character_limits(self):
        for op, pattern, field in [('grep', 'hello', 'matches'), ('glob', '*.py', 'paths')]:
            result = self.call(op, pattern, limit=1)
            self.assertEqual(len(result[field]), 1)
            self.assertTrue(result['truncated'])
        (self.root / 'long.txt').write_text('中' * 10000)
        result = self.call('grep', '中', max_chars=128)
        self.assertTrue(result['truncated'])
        self.assertTrue(result['matches'][0]['text_truncated'])
        m = result['matches'][0]
        self.assertLessEqual(len(f"{m['path']}:{m['line']}: {m['text']}\n"), 128)
        result = self.call('glob', '*', max_chars=128, all=True)
        self.assertLessEqual(sum(len(p) + 1 for p in result['paths']), 128)

    def test_special_names_leading_dash_and_no_symlink_recursion(self):
        name = "space ' 中文 $x\nfile.txt"
        (self.root / name).write_text('--special\n')
        (self.root / 'loop').symlink_to(self.root, target_is_directory=True)
        result = self.call('grep', '--special', literal=True)
        self.assertEqual(result['matches'][0]['path'], name)
        self.assertIn(name, self.call('glob', '*.txt')['paths'])
        self.assertFalse(any('loop/' in p for p in self.call('glob', '*', all=True)['paths']))

    def test_user_rg_config_does_not_change_protocol(self):
        config = self.root / 'rg-config'
        config.write_text('--files-with-matches\n')
        with patch.dict(os.environ, {'RIPGREP_CONFIG_PATH': str(config)}):
            self.assertEqual(len(self.call('grep', 'Hello')['matches']), 1)

    def test_missing_dependency_is_actionable(self):
        with patch.object(FILES.shutil, 'which', return_value=None), patch.object(FILES.Path, 'home', return_value=self.root):
            with self.assertRaises(FILES.FileError) as raised:
                self.call('glob', '*')
            self.assertEqual(raised.exception.code, 'missing_dependency')

    def test_record_reader_bounds_and_null_delimiters(self):
        self.assertEqual(list(FILES.search_records(io.BytesIO(b'a\nb\0c\0'), b'\0')), [b'a\nb', b'c'])
        with patch.object(FILES, 'MAX_BYTES', 32), self.assertRaises(FILES.FileError) as raised:
            list(FILES.search_records(io.BytesIO(b'x' * 33), b'\n'))
        self.assertEqual(raised.exception.code, 'search_record_too_large')


if __name__ == '__main__':
    unittest.main()
