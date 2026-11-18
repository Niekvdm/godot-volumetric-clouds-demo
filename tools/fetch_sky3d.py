#!/usr/bin/env python3
"""Fetch Sky3D (https://github.com/TokisanGames/Sky3D) into addons/sky_3d.

The demo runs on Sky3D as released, unmodified, so it is not committed here: this script downloads the
pinned release from the upstream repository and places its addon folder where the project expects it.

    python3 tools/fetch_sky3d.py            # fetch v2.1.0 unless addons/sky_3d is already there
    python3 tools/fetch_sky3d.py --force    # replace an existing addons/sky_3d
    python3 tools/fetch_sky3d.py --tag v2.1.0

Needs only Python 3 (no git). Works on Linux, macOS and Windows.
"""
import argparse
import io
import os
import shutil
import sys
import urllib.request
import zipfile

REPO = "TokisanGames/Sky3D"
TAG = "v2.1.0"
ADDON = "addons/sky_3d"
ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))


def main():
	ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
	ap.add_argument("--tag", default=TAG, help="Sky3D release tag (default %s)" % TAG)
	ap.add_argument("--force", action="store_true", help="replace an existing addons/sky_3d")
	a = ap.parse_args()

	dest = os.path.join(ROOT, *ADDON.split("/"))
	if os.path.isfile(os.path.join(dest, "plugin.cfg")) and not a.force:
		print("[sky3d] %s is already there (use --force to replace it)" % ADDON)
		return 0

	url = "https://github.com/%s/archive/refs/tags/%s.zip" % (REPO, a.tag)
	print("[sky3d] downloading %s" % url)
	with urllib.request.urlopen(url, timeout=120) as r:
		data = r.read()
	zf = zipfile.ZipFile(io.BytesIO(data))
	names = zf.namelist()
	top = names[0].split("/")[0]  # Sky3D-2.1.0/
	prefix = "%s/%s/" % (top, ADDON)
	members = [n for n in names if n.startswith(prefix)]
	if not members:
		print("[sky3d] %s not found in the %s archive" % (ADDON, a.tag), file=sys.stderr)
		return 1

	if os.path.isdir(dest):
		shutil.rmtree(dest)
	for n in members:
		rel = n[len(prefix):]
		if not rel:
			continue
		out = os.path.join(dest, *rel.split("/"))
		if n.endswith("/"):
			os.makedirs(out, exist_ok=True)
			continue
		os.makedirs(os.path.dirname(out), exist_ok=True)
		with zf.open(n) as src, open(out, "wb") as dst:
			shutil.copyfileobj(src, dst)

	if not os.path.isfile(os.path.join(dest, "plugin.cfg")):
		print("[sky3d] extracted, but %s/plugin.cfg is missing" % ADDON, file=sys.stderr)
		return 1
	print("[sky3d] Sky3D %s placed in %s (%d files)" % (a.tag, ADDON, sum(1 for n in members if not n.endswith("/"))))
	return 0


if __name__ == "__main__":
	sys.exit(main())
