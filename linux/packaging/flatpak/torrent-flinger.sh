#!/bin/sh
# Flatpak launcher: PySide6 comes from the BaseApp under /app/lib/python3.*/
for d in /app/lib/python3.*/site-packages; do
    PYTHONPATH="$d${PYTHONPATH:+:$PYTHONPATH}"
done
PYTHONPATH="/app/share/torrent-flinger${PYTHONPATH:+:$PYTHONPATH}"
export PYTHONPATH
exec python3 -m flinger "$@"
