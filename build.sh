#!/bin/sh

version="$(cat module.prop | grep 'version=' | awk -F '=' '{print $2}')"
id="$(cat module.prop | grep 'id=' | awk -F '=' '{print $2}')"
zip_file="${id}-${version}.zip"
[ -f "$zip_file" ] && rm -rf "$zip_file"
zip -r -o -X -ll "$zip_file" ./ -x '.git/*' -x '.github/*' -x 'docs/*' -x 'build.sh' -x 'README.md' -x 'LICENSE'
