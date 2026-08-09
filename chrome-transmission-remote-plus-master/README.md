# Remote Transmission ++

Based on Remote Transmission Plus

## Features
* Click a torrent link to download it using a remote Transmission client
  * click on most torrent links to automatically send it to Transmission
  * right-click any link to send to Transmission
  * custom download directories
  * browser icon notification badges: add, dup, fail
  * hold down ALT, CTRL, or SHIFT to download the torrent file locally


* Remote Control
  * notifications when a torrent download completes
  * filter by name and status
  * pause and resume torrents
  * remove torrents (double-click) with data (CTRL + double-click)
  * toggle turtle mode


## Changelog

2018-01-25 v1.0.8
* Fix popup not appearing correctly on OSX (thanks wader)

2017-10-02 v1.0.7
* Fix notification on completed torrent (thanks slokhorst)

2017-10-02 v1.0.6
* Fix adding torrents in the paused state (thanks slokhorst)

2017-10-01 v1.0.5
* Update to jQuery v3.2.1 (thanks slokhorst)
* Fix some options not being saved (thanks slokhorst)

2017-03-13 v1.0.4
* Fix "download directory path is not absolute" error. (Closes issue #28) (thanks zsorizs)
* Fix configuration resetting to defaults when opened. (thanks zsorizs)
* Fix saving of default click action. (thanks zsorizs)

2016-02-03 v1.0.3
* Fix capturing links for dynamically loaded content

2015-06-06 V1.0.1
* Fix for last version erasing settings

2015-06-03 v1.0.0
* Add support for adding new custom location from save popup (thanks wader)

2015-04-15 v0.9.9.9
* Ensure clients' filters are not changed erroneously

2015-04-13 v0.9.9.8
* Fixed filtering (presumably broken for some time due to RPC changes)
* Added a filtering category 'Active' to filter out stopped/completed torrents. (Closes issue #10).

2015-04-12 v0.9.9.7
* Give the popup a minimum height so the buttons are always clickable (thanks jonathantribouharet)
* Clear all previous torrents on error (thanks jonathantribouharet) hopefully stops torrents showing up multiple times.

## Credits / Contributors
* dz0ny
  * (probably) the original developer
* cherepanov
  * This extension is based upon his improvements dz0ny's work
* sakim
* r04r
* mjbnz
* jonathantribouharet
* wader
* zsorizs
* iancorbitt
* slokhorst
