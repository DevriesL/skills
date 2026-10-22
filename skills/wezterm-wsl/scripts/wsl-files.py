"""Bounded UTF-8 file operations inside WSL; invoked by the WezTerm bridge."""
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

MAX_BYTES = 8 * 1024 * 1024


class FileError(Exception):
    def __init__(self, code, message):
        self.code = code
        super().__init__(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def path_arg(request, key="path"):
    value = request.get(key)
    if not isinstance(value, str) or not value or "\0" in value:
        raise FileError("invalid_request", f"{key} must be a nonempty path")
    return Path(os.path.abspath(os.path.expanduser(value)))


def text_arg(request, key):
    value = request.get(key)
    if not isinstance(value, str):
        raise FileError("invalid_request", f"{key} must be a string")
    return value


def bounded_int(request, key, default, minimum, maximum):
    value = request.get(key, default)
    if type(value) is not int or not minimum <= value <= maximum:
        raise FileError("invalid_request", f"{key} must be {minimum}..{maximum}")
    return value


def load_text(path):
    info = path.stat()
    if not stat.S_ISREG(info.st_mode):
        raise FileError("not_regular", f"Not a regular file: {path}")
    with path.open("rb") as stream:
        data = stream.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise FileError("too_large", "File exceeds 8 MiB; use exec for large/binary files")
    if b"\0" in data:
        raise FileError("binary_file", "File contains NUL bytes; use exec for binary files")
    try:
        return data, data.decode("utf-8"), info
    except UnicodeDecodeError as error:
        raise FileError("encoding", "File is not UTF-8; use exec to select an encoding") from error


def expected(request, data):
    wanted = request.get("expected_hash")
    if wanted is not None and wanted != digest(data):
        raise FileError("conflict", "File changed: expected_hash does not match; read it again")


def newline_text(value, original=None):
    # Retain a consistent existing CRLF convention; new files default to LF.
    newline = "\r\n" if original and "\r\n" in original and "\n" not in original.replace("\r\n", "") else "\n"
    return value.replace("\r\n", "\n").replace("\n", newline)


def signature(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def replace_text(path, data, original=None, info=None):
    if len(data) > MAX_BYTES:
        raise FileError("too_large", "Result exceeds 8 MiB")
    if info is None:
        # Exclusive creation refuses a destination created since the first check.
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o666)
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        return
    if info.st_nlink != 1 or info.st_uid != os.geteuid():
        raise FileError("special_file", "Use exec for hard-linked files or files owned by another user")
    if not os.access(path, os.W_OK):
        raise FileError("permission", f"File is not writable: {path}")
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fchown(stream.fileno(), info.st_uid, info.st_gid)
            os.fchmod(stream.fileno(), stat.S_IMODE(info.st_mode))
            for name in os.listxattr(path):
                os.setxattr(temporary, name, os.getxattr(path, name))
            os.fsync(stream.fileno())
        # Best-effort concurrent-change detection; this is not a filesystem CAS.
        current = path.lstat()
        if signature(current) != signature(info) or path.read_bytes() != original:
            raise FileError("conflict", "File changed during the operation; read it again")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def execute(request):
    if not isinstance(request, dict):
        raise FileError("invalid_request", "Request must be an object")
    for key in ("all", "overwrite", "parents"):
        if key in request and type(request[key]) is not bool:
            raise FileError("invalid_request", f"{key} must be a boolean")
    operation = request.get("op")
    path = path_arg(request)
    if operation == "ls":
        limit = bounded_int(request, "limit", 100, 1, 1000)
        maximum = bounded_int(request, "max_chars", 4000, 128, 100000)
        with os.scandir(path) as scan:
            entries = sorted((entry for entry in scan if request.get("all") or not entry.name.startswith(".")), key=lambda entry: entry.name)
        items = []
        used = 0
        for entry in entries[:limit]:
            if used + len(entry.name) + 2 > maximum:
                break
            kind = "link" if entry.is_symlink() else "dir" if entry.is_dir(follow_symlinks=False) else "file"
            items.append({"name": entry.name, "type": kind})
            used += len(entry.name) + 2
        return {"op": operation, "path": str(path), "entries": items, "omitted": len(entries) - len(items)}

    if operation == "read":
        start = bounded_int(request, "from", 1, 1, 1000000000)
        count = bounded_int(request, "lines", 120, 1, 10000)
        maximum = bounded_int(request, "max_chars", 4000, 128, 100000)
        data, content, _ = load_text(path)
        lines = content.splitlines(keepends=True)
        selection = "".join(lines[start - 1:start - 1 + count])
        clipped = selection[:maximum]
        return {"op": operation, "path": str(path), "sha256": digest(data), "total_lines": len(lines),
                "from": start, "content": clipped,
                "truncated": len(clipped) < len(selection) or start - 1 + count < len(lines)}

    if operation in ("write", "edit"):
        if path.is_symlink():
            raise FileError("symlink", "Refusing to replace a symlink; use its explicit target or exec")
        exists = path.exists()
        data, content, info = load_text(path) if exists else (None, None, None)
        if operation == "edit" and not exists:
            raise FileError("not_found", f"File does not exist: {path}")
        if exists:
            expected(request, data)
            if operation == "write" and not request.get("overwrite") and "expected_hash" not in request:
                raise FileError("exists", "File exists; supply expected_hash or overwrite=true")
        elif "expected_hash" in request:
            raise FileError("conflict", "Expected an existing file, but the path is missing")
        replacements = None
        if operation == "edit":
            old = newline_text(text_arg(request, "old"), content)
            new = newline_text(text_arg(request, "new"), content)
            if not old:
                raise FileError("invalid_request", "old cannot be empty")
            replacements = content.count(old)
            if not replacements or (replacements != 1 and not request.get("all")):
                raise FileError("match_count", f"Expected one match, found {replacements}; use all=true for multiple matches")
            updated = content.replace(old, new)
        else:
            updated = newline_text(text_arg(request, "content"), content)
        if request.get("parents"):
            path.parent.mkdir(parents=True, exist_ok=True)
        encoded = updated.encode("utf-8")
        if b"\0" in encoded:
            raise FileError("binary_file", "Use exec for binary files")
        replace_text(path, encoded, data, info)
        result = {"op": operation, "path": str(path), "bytes": len(encoded), "sha256": digest(encoded)}
        if replacements is not None:
            result["replacements"] = replacements
        return result

    if operation == "mv":
        destination = path_arg(request, "to")
        if path == destination:
            raise FileError("same_path", "Source and destination are identical")
        if "expected_hash" in request:
            if path.is_symlink():
                raise FileError("symlink", "Hash checks on symlink moves are unsupported")
            expected(request, load_text(path)[0])
        if request.get("parents"):
            destination.parent.mkdir(parents=True, exist_ok=True)
        # GNU mv handles directory and cross-filesystem moves. -T means an exact
        # destination. -n never overwrites; detect its successful-but-skipped case.
        mode = "-f" if request.get("overwrite") else "-n"
        move = subprocess.run(["mv", "-T", mode, "--", str(path), str(destination)], capture_output=True, text=True)
        if move.returncode:
            raise FileError("move_failed", move.stderr.strip())
        if os.path.lexists(path):
            raise FileError("exists", f"Move skipped; destination exists: {destination}")
        return {"op": operation, "path": str(path), "to": str(destination)}
    raise FileError("invalid_request", f"Unsupported operation: {operation}")


def main():
    response_path = Path(sys.argv[2])
    try:
        request = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8-sig"))
        result = {"ok": True, **execute(request)}
    except (FileError, OSError, ValueError) as error:
        result = {"ok": False, "error": {"code": getattr(error, "code", type(error).__name__), "message": str(error)}}
    temporary = response_path.with_suffix(".tmp")
    temporary.write_text(json.dumps(result, ensure_ascii=False), encoding="utf-8")
    os.replace(temporary, response_path)
    # Keep the shared terminal useful; the bridge returns the structured file.
    if result["ok"]:
        print(f"{result['op']} {result['path']}")
    else:
        print(result["error"]["message"], file=sys.stderr)
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
