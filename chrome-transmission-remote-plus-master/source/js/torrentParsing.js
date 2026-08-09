/* exported parseTorrent */
/**
 * Parses the torrent into a javascript object
 * @param {String} torrent - a torrent file
 * @param {Function} callback - where to send the parsed torrent object
 */
function parseTorrent(torrent, callback) {
  var reader = new FileReader();
  reader.onload = function () {
    var worker = new Worker('js/bencode.js');
    worker.onmessage = function (ev) {
      if (ev.data.split) {
        let data = ev.data.split(':');
        switch (true) {
          case data[0] === 'debug':
            console.debug(data[1]); // eslint-disable-line no-console
            break;
          default:
            break;
        }
      } else {
        callback(ev.data);
      }
    };
    worker.onerror = function (event) {
      throw new Error(event.message + ' (' + event.filename + ':' + event.lineno + ')');
    };
    worker.postMessage(reader.result);
  };

  reader.readAsBinaryString(new Blob([torrent], {type: 'application/octet-stream'}));
}

/* exported encodeFile */
/**
 * Encodes a file into base64
 * @param {String} file - file
 * @param {Function} callback - where to send the base64 encoded file
 */
function encodeFile(file, callback) {
  // callback(btoa(unescape(encodeURIComponent( file ))));
  var reader = new FileReader();

  reader.onload = function () {
    // assume base64 and just split to get data
    // data:[<MIME-type>][;charset=<encoding>][;base64],<data>
    var parts = reader.result.split(',', 2);
    callback(parts[1]);
  };

  reader.readAsDataURL(file);
}

/* exported getFile */
/*
 * Downloads a file
 * @param {String} url - URL of the file to download and encode
 * @param {Functino} callback - where to send the downloaded file
 */
function getFile(url, callback) {
  var xhr = new XMLHttpRequest();
  xhr.open('GET', url, true);
  xhr.responseType = 'blob';
  xhr.onload = function () {
    if (this.status === 200) {
      callback(this.response);
    }
  };
  xhr.send();
}
