#!/usr/bin/env python3
"""Package generated .app files with explicit UTF-8 names and executable Unix modes."""
import os
import stat
import sys
from pathlib import Path
from zipfile import ZipFile, ZipInfo, ZIP_DEFLATED, ZIP_STORED

app, output = (Path(value).resolve() for value in sys.argv[1:3])
temporary = output.with_suffix('.partial.zip')
with ZipFile(temporary, 'w', compression=ZIP_DEFLATED, compresslevel=4) as archive:
    for entry in [app, *sorted(app.rglob('*'))]:
        if entry.is_symlink():
            target = entry.resolve(strict=True)
            if not target.is_relative_to(app):
                raise RuntimeError('Symbolic link leaves application: ' + str(entry))
            info = ZipInfo(entry.relative_to(app.parent).as_posix())
            info.create_system = 3
            info.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(info, os.readlink(entry), compress_type=ZIP_STORED)
        else:
            archive.write(entry, entry.relative_to(app.parent).as_posix())
with ZipFile(temporary) as archive:
    if archive.testzip() is not None:
        raise RuntimeError('Package integrity check failed')
    if not all(item.filename.startswith(app.name + '/') for item in archive.infolist()):
        raise RuntimeError('Unexpected archive path')
os.replace(temporary, output)
