// Bridge between the Flutter web app and tdweb (TDLib compiled to
// WebAssembly, loaded from tdweb.js). Requests and responses cross the
// bridge as JSON strings. Browser files (Blobs) cannot be JSON, so they are
// kept here and referred to by number.
(function () {
  'use strict';

  var client = null;
  var blobs = new Map();
  var nextBlobId = 1;

  // Replaces {"@type": "inputFileBlob", "blob_id": n} with the real Blob.
  function attachBlobs(value) {
    if (Array.isArray(value)) return value.map(attachBlobs);
    if (value && typeof value === 'object') {
      if (value['@type'] === 'inputFileBlob' && typeof value.blob_id === 'number') {
        var blob = blobs.get(value.blob_id);
        if (!blob) throw new Error('Unknown blob ' + value.blob_id);
        return { '@type': 'inputFileBlob', name: value.name, data: blob };
      }
      var out = {};
      for (var key in value) out[key] = attachBlobs(value[key]);
      return out;
    }
    return value;
  }

  // Blobs in responses (file parts) are dropped from the JSON: the app reads
  // file contents through readFileUrl instead.
  function toJson(value) {
    return JSON.stringify(value, function (key, v) {
      return v instanceof Blob ? null : v;
    });
  }

  window.tedriveTd = {
    available: function () {
      return typeof window.tdweb !== 'undefined' && !!window.tdweb.default;
    },

    // Starts TDLib. onUpdate receives every update as a JSON string.
    // After the session closes (log out), calling this again starts a new one.
    create: function (onUpdate) {
      if (client) return;
      var TdClient = window.tdweb.default;
      var current = new TdClient({
        instanceName: 'tedrive',
        mode: 'wasm',
        useDatabase: true,
        jsLogVerbosityLevel: 'error',
        logVerbosityLevel: 1,
        onUpdate: function (update) {
          var state = update['@type'] === 'updateAuthorizationState' &&
            update.authorization_state && update.authorization_state['@type'];
          if (state === 'authorizationStateClosed' && client === current) client = null;
          onUpdate(toJson(update));
        },
      });
      client = current;
    },

    // Sends a request (JSON string); resolves with the reply as a JSON
    // string. TDLib errors resolve too, as {"@type": "error", ...}.
    send: function (json) {
      var query = attachBlobs(JSON.parse(json));
      return client.send(query).then(toJson, function (error) {
        return toJson(error && error['@type'] === 'error'
          ? error
          : { '@type': 'error', code: 500, message: String(error && error.message || error) });
      });
    },

    // Fetches a browser file (for example one the user picked, given by its
    // blob: URL) and keeps it for an upload. Returns its number.
    putBlobFromUrl: function (url) {
      return fetch(url).then(function (r) { return r.blob(); }).then(function (blob) {
        var id = nextBlobId++;
        blobs.set(id, blob);
        return id;
      });
    },

    releaseBlob: function (id) {
      blobs.delete(id);
    },

    // A blob: URL for a downloaded file, which the app can show, play or
    // save. Resolves with null if the file is not downloaded.
    readFileUrl: function (fileId, mime) {
      return client.send({ '@type': 'readFile', file_id: fileId }).then(function (r) {
        if (!r || !r.data) return null;
        var blob = mime ? new Blob([r.data], { type: mime }) : r.data;
        return URL.createObjectURL(blob);
      }, function () { return null; });
    },

    // Saves a blob: URL to the user's downloads under the given name.
    saveUrl: function (url, name) {
      var a = document.createElement('a');
      a.href = url;
      a.download = name;
      document.body.appendChild(a);
      a.click();
      a.remove();
    },

    openUrl: function (url) {
      window.open(url, '_blank', 'noopener');
    },
  };
})();
