// chrome-extension://hniolkcjkcfecgnhgpmeddfhndceheci/popup.html

/* global formatBytes */

const TR_STATUS_STOPPED        = 0; /* Torrent is stopped */
const TR_STATUS_CHECK_WAIT     = 1; /* Queued to check files */
const TR_STATUS_CHECK          = 2; /* Checking files */
const TR_STATUS_DOWNLOAD_WAIT  = 3; /* Queued to download */
const TR_STATUS_DOWNLOAD       = 4; /* Downloading */
const TR_STATUS_SEED_WAIT      = 5; /* Queued to seed */
const TR_STATUS_SEED           = 6; /* Seeding */

/* exported Torrent */
function Torrent() {

  var oPauseBtn;
  var oResumeBtn;
  var oRemoveBtn;
  var oProgress;
  var oProgressBar;
  var oStats;
  var oSpeeds;
  var oRoot = jQuery('<li></li>');

  this.id = 0;
  this.name = '';
  this.status = -1;

  // send RPC for a torrent
  this.sendRPC = function (method, altDown) {
    var deleteCmd;
    clearTimeout(refresh);
    deleteCmd = (method === 'torrent-remove' && altDown) ? ', "delete-local-data": true' : '';
    port.postMessage({args: '"ids": [ ' + this.id + ' ]' + deleteCmd, method: method});
    refresh = setTimeout(refreshPopup, method === 'torrent-stop' ? 500 : 0);
  };

  // test the torrent name against the current filter and set whether it's visible or not
  this.filter = function () {
    var filter = !localStorage.torrentFilter ? '' : new RegExp(localStorage.torrentFilter.replace(/ /g, '[^A-z0-9]*'), 'i');
    var type = localStorage.torrentType || -1;

    console.log(filter);
    console.log(type);

    if ((type === '-1' || this.status === type || type.indexOf(this.status) > -1) && this.name.search(filter) > -1) {
      jQuery('#list').append(oRoot);
    } else {
      jQuery('#list_hidden').append(oRoot);
    }
  };

  function adjustButtons(status) {
    oPauseBtn.toggle(status === TR_STATUS_CHECK_WAIT || status === TR_STATUS_CHECK || status === TR_STATUS_DOWNLOAD_WAIT || status === TR_STATUS_DOWNLOAD || status === TR_STATUS_SEED_WAIT || status === TR_STATUS_SEED);
    oResumeBtn.toggle(status === TR_STATUS_STOPPED || status === TR_STATUS_DOWNLOAD_WAIT);
  }

  function adjustLabels(props, percentDone) {
    switch (props.status) {
      case TR_STATUS_CHECK_WAIT:
        oStats.text(formatBytes(props.sizeWhenDone - props.leftUntilDone) + ' of ' + formatBytes(props.sizeWhenDone) + ' (' + percentDone.toFixed(2) + '%) - waiting to verify local data');
        oSpeeds.text('');
        break;
      case TR_STATUS_CHECK:
        oStats.text(formatBytes(props.sizeWhenDone - props.leftUntilDone) + ' of ' + formatBytes(props.sizeWhenDone) + ' (' + percentDone.toFixed(2) + '%) - verifying local data (' + (props.recheckProgress * 100).toFixed() + '%)');
        oSpeeds.text('');
        break;
      case TR_STATUS_DOWNLOAD:
        if (props.metadataPercentComplete < 1) {
          oStats.text('Magnetized transfer - retrieving metadata (' + (props.metadataPercentComplete * 100).toFixed() + '%)');
          oSpeeds.text('');
          oProgress.attr('class', 'torrent_progress magnetizing');
        } else {
          oStats.text(formatBytes(props.sizeWhenDone - props.leftUntilDone) + ' of ' + formatBytes(props.sizeWhenDone) + ' (' + percentDone.toFixed(2) + '%) - ' + formatSeconds(props.eta) + ' remaining');
          oSpeeds.text('DL: ' + formatBytes(props.rateDownload) + '/s UL: ' + formatBytes(props.rateUpload) + '/s');
        }
        break;
      case TR_STATUS_SEED:
        oStats.text(formatBytes(props.sizeWhenDone) + ' - Seeding, uploaded ' + formatBytes(props.uploadedEver) + ' (Ratio ' + (props.uploadedEver / props.sizeWhenDone).toFixed(2) + ')');
        oSpeeds.text('UL: ' + formatBytes(props.rateUpload) + '/s');
        oProgressBar.attr('class', 'seeding');
        break;
      case TR_STATUS_STOPPED:
        if (props.leftUntilDone) {
          oStats.text(formatBytes(props.sizeWhenDone - props.leftUntilDone) + ' of ' + formatBytes(props.sizeWhenDone) + ' (' + percentDone.toFixed(2) + '%) - Paused');
          oProgressBar.attr('class', 'paused');
        } else {
          let done = (props.doneDate > 0) ? props.doneDate : props.addedDate;
          oStats.text(formatBytes(props.sizeWhenDone) + ' - Completed on ' + new Date(done * 1000).toLocaleDateString());
          oProgressBar.attr('class', 'complete');
        }
        oSpeeds.text('');
        break;
      default:
        break;
    }
  }

  function adjustProgress(percentDone) {
    if (percentDone === 100) {
      oProgressBar.attr('class', 'complete').css('width', percentDone + '%');
    } else if (percentDone > 0) {
      oProgressBar.attr('class', 'downloading').css('width', percentDone + '%');
    } else {
      oProgressBar.hide();
    }
  }

  // create the list element and update torrent properties
  this.createElem = function (props) {

    var self;
    var progress;

    this.id = props.id;
    this.name = props.name;
    this.status = props.status;

    self = this;
    progress = 100 - (props.leftUntilDone / props.sizeWhenDone * 100);

    oName = jQuery('<div>' + props.name + '</div>').attr({
      class : 'torrent_name',
      title : props.name + '\n\nDownloaded to: ' + props.downloadDir,
    }).appendTo(oRoot);

    oStats = jQuery('<div></div>').attr({
      class: 'torrent_stats',
    }).appendTo(oRoot);

    oSpeeds = jQuery('<div></div>').attr({
      class: 'torrent_speeds',
    }).appendTo(oRoot);

    oProgress = jQuery('<div></div>').attr({
      class: 'torrent_progress',
    }).appendTo(oRoot);

    oProgressBar = jQuery('<div></div>').appendTo(oProgress);

    oPauseBtn = jQuery('<div></div>').attr({
      class : 'torrent_button pause',
      title : 'Pause',
    }).click(function (e) {
      self.sendRPC('torrent-stop');
    }).appendTo(oRoot);

    oResumeBtn = jQuery('<div></div>').attr({
      class : 'torrent_button resume',
      title : 'Resume',
    }).click(function () {
      self.sendRPC('torrent-start');
    }).appendTo(oRoot);

    oRemoveBtn = jQuery('<div></div>').attr({
      name  : 'torrent_remove',
      class : 'torrent_button remove',
      title : 'Double-click to remove torrent\n\nHold down ALT to also delete data',
    }).dblclick(function (e) {
      self.sendRPC('torrent-remove', e.altKey);
    }).mousedown(function (e) {	// prevent text being selected on double-click
      e.preventDefault();
    }).appendTo(oRoot);

    adjustProgress(progress);
    adjustButtons(props.status);
    adjustLabels(props, progress);
  };

  // update the list element and update torrent properties
  this.updateElem = function (props) {

    var progress = 100 - (props.leftUntilDone / props.sizeWhenDone * 100);

    this.status = props.status;

    oName.attr('title', props.name + '\n\nDownloaded to: ' + props.downloadDir);
    oProgress.attr('class', 'torrent_progress');

    adjustProgress(progress);
    adjustButtons(props.status);
    adjustLabels(props, progress);
  };

  // remove the list element for torrent
  this.removeElem = function () {
    oRoot.remove();
  };
}
