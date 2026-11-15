#!/bin/sh
# Write index.html for the package repositories on the gh-pages branch.
#
#   tools/pages-index.sh <site dir> <owner/repo> [tag with a release ...]
#
# <site dir> holds one directory per release (ra81-<label>-run<N>, each with
# packages.adb). Newest run first. A directory gets a link to its GitHub
# release only if its tag is listed, so a deleted release leaves no dead link.
# The site has .nojekyll, so GitHub Pages serves this file as is (an index.md
# would not be rendered).
set -eu
[ $# -ge 2 ] || { echo "usage: $0 <site dir> <owner/repo> [tag ...]" >&2; exit 2; }
site=$1 repo=$2
shift 2
cd "$site"

has_release() {
	for t in "$@"; do [ "$t" = "$d" ] && return 0; done
	return 1
}

{
	cat <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>RA81 OpenWrt package repositories</title>
<style>
body { font: 16px/1.5 system-ui, sans-serif; max-width: 46rem; margin: 2rem auto; padding: 0 1rem; color: #1f2328; background: #fff; }
code { font-size: 0.9em; background: #f0f2f4; padding: 0.1em 0.3em; border-radius: 4px; }
a { color: #0969da; }
@media (prefers-color-scheme: dark) {
  body { color: #e6edf3; background: #0d1117; }
  code { background: #262c36; }
  a { color: #4493f8; }
}
</style>
</head>
<body>
<h1>RA81 OpenWrt package repositories</h1>
<p>Package repositories of the <a href="https://github.com/$repo">$repo</a> firmware
for the Xiaomi Redmi AX3000 (RA81): the kernel modules and other packages of each
release. They only install on an image of the same release, which already lists its
repository in <code>/etc/apk/repositories.d/distfeeds.list</code>, so
<code>apk update &amp;&amp; apk add kmod-&lt;name&gt;</code> is all that is needed.</p>
<p>Firmware downloads: <a href="https://github.com/$repo/releases/latest">latest release</a>.</p>
<ul>
EOF
	for d in $(for d in ra81-*-run*; do [ -d "$d" ] && echo "${d##*-run} $d"; done | sort -rn | cut -d' ' -f2); do
		line="<li><a href=\"$d/packages.adb\">$d</a>"
		if has_release "$@"; then
			line="$line (<a href=\"https://github.com/$repo/releases/tag/$d\">release</a>)"
		fi
		echo "$line</li>"
	done
	cat <<EOF
</ul>
</body>
</html>
EOF
} > index.html
rm -f index.md
