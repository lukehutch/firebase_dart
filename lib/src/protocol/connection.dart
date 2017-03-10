// Copyright (c) 2016, Rik Bellens. All rights reserved. Use of this source code
// is governed by a BSD-style license that can be found in the LICENSE file.

part of firebase.protocol;

class ServerError implements Exception {
  final String code;
  final String message;

  ServerError(this.code, this.message);

  String get reason =>
      const {
        "too_big":
            "The data requested exceeds the maximum size that can be accessed with a single request.",
        "permission_denied":
            "Client doesn't have permission to access the desired data.",
        "unavailable": "The service is unavailable"
      }[code] ??
      "Unknown Error";

  @override
  String toString() => "$code: $reason";
}

enum OperationEventType {overwrite, merge, listenRevoked}

class OperationEvent {
  final Path<Name> path;
  final OperationEventType type;
  final Query query;
  final TreeStructuredData data;

  OperationEvent(this.type, this.path, this.data, this.query);

  TreeOperation get operation {
    switch (type) {
      case OperationEventType.overwrite:
        if (path.isNotEmpty&&path.last==new Name(".priority"))
          return new TreeOperation.setPriority(path.parent, data.value);
        return new TreeOperation.overwrite(path, data);
      case OperationEventType.merge:
        return new TreeOperation.merge(path, data.children);
      default:
        return null;
    }
  }
}

class Connection {
  final String host;
  Transport _transport;
  Future _establishConnectionTimer;
  String _lastSessionId;

  int _nextTag = 0;
  final quiver.BiMap<int,Pair<String,Query>> _tagToQuery = new quiver.BiMap();

  Connection(this.host) {
    quiver.checkArgument(host!=null&&host.isNotEmpty);
    _scheduleConnect(0);
  }

  final Map<String, Map<Query, Request>> _listens = {};

  DateTime get serverTime => new DateTime.now().add(_serverTimeDiff ?? const Duration());
  Duration _serverTimeDiff;

  Future<Iterable<String>> listen(String path, {Query query, String hash}) async {
    var def = new Pair(path, query);
    var tag = _nextTag++;
    _tagToQuery[tag] = def;

    var r = new Request.listen(path, query: query, tag: tag, hash: hash);
    _addListen(r);
    try {
      var body = await _request(r);
      return body.warnings ?? [];
    } catch(e) {
      _tagToQuery.remove(tag);
      _removeListen(path, query);
      rethrow;
    }
  }

  Future<Null> unlisten(String path, {Query query}) async {
    var def = new Pair(path, query);
    var tag = _tagToQuery.inverse.remove(def);
    var r = new Request.unlisten(path, query: query, tag: tag);
    _removeListen(path, query);
    await _request(r);
  }

  final List<Request> _outstandingRequests = [];

  Future<Null> put(String path, dynamic value, {String hash, int writeId}) async {
    await _request(new Request.put(path, value, hash, writeId));
  }

  Future<Null> merge(String path, dynamic value, {String hash, int writeId}) async {
    await _request(new Request.merge(path, value, hash, writeId));
  }

  void _addListen(Request request) {
    var path = request.message.body.path;
    var query = request.message.body.query;
    _listens.putIfAbsent(path, () => {})[query] = request;
  }

  void _removeListen(String path, Query query) {
    _listens.putIfAbsent(path, () => {}).remove(query);
  }

  void _scheduleConnect(num timeout) {
    assert(this._transport ==
        null); //, "Scheduling a connect when we're already connected/ing?");

    var future = this._establishConnectionTimer =
        new Future.delayed(new Duration(milliseconds: timeout.floor()));

    future.then((_) {
      if (future != _establishConnectionTimer) {
        return;
      }
      _establishConnectionTimer = null;
      _establishConnection();
    });
  }

  final StreamController<bool> _onConnect = new StreamController();
  final StreamController<OperationEvent> _onDataOperation = new StreamController();
  final StreamController<Map> _onAuth = new StreamController();

  Stream<bool> get onConnect => _onConnect.stream;
  Stream<OperationEvent> get onDataOperation => _onDataOperation.stream;
  Stream<Map> get onAuth => _onAuth.stream;


  void _establishConnection() {
    _transport =
        new WebSocketTransport(host, host.split(".").first, _lastSessionId);
    _transport.ready.then((_) {
      _onConnect.add(true);
      _lastSessionId = _transport.info.sessionId;
      _serverTimeDiff =
          _transport.info.timestamp.difference(new DateTime.now());
      _transport
      .where((r)=>r.message.reqNum == null)
      .forEach((r) {
        var query = r.message.body.query ?? _tagToQuery[r.message.body.tag]?.value;
        var path = r.message.body.path==null ? null : Name.parsePath(r.message.body.path);
        var newData = new TreeStructuredData.fromJson(r.message.body.data);
        switch (r.message.action) {
          case DataMessage.actionSet:
          case DataMessage.actionMerge:
          case DataMessage.actionListenRevoked:
            var event = new OperationEvent(const {
              DataMessage.actionSet: OperationEventType.overwrite,
              DataMessage.actionMerge: OperationEventType.merge,
              DataMessage.actionListenRevoked: OperationEventType.listenRevoked,
            }[r.message.action], path, newData, query);
            _onDataOperation.add(event);
            break;
          case DataMessage.actionAuthRevoked:
            _onAuth.add(null);
            break;
          case DataMessage.actionSecurityDebug:
            var msg = r.message.body.message;
            _logger.fine("security debug: $msg");
            break;
          default:
            throw new UnimplementedError(
                "Cannot handle message with action ${r.message.action}: ${JSON.encode(r.message)} ${r.message.reqNum} ${r.request.writeId}");
        }

      });
      _restoreState();
    });
    _transport.done.then((_) {
      _onConnect.add(false);
      _transport = null;
      if (!_onDataOperation.isClosed) _scheduleConnect(1000);
    });
  }

  Future disconnect() => _transport._close(-1);

  Future close() async {
    await _onDataOperation.close();
    await _onAuth.close();
    await _onConnect.close();
    await disconnect();
  }

  Future _restoreState() async {
    if (_transport.readyState!=Transport.connected) return;


    // auth
    if (_authToken != null) {
      await auth(_authToken);
    }

    // listens
    _listens.forEach((path, list) {
      list.forEach((query, request) {
        _transport.add(request);
      });
    });

    // requests
    _outstandingRequests.forEach((r) {
      _transport.add(r);
    });
  }

  var _authToken;

  Future<Map> auth(String token) => _request(new Request.auth(token)).then((b) {
        _authToken = token;
        return b.data["auth"];
      });

  Future unauth() {
    _authToken = null;
    return _request(new Request.unauth()).then((b) => b.data);
  }

  bool get _transportIsReady =>
      _transport != null && _transport.readyState == Transport.connected;

  Future<MessageBody> _request(Request request) {
    switch (request.message.action) {
      case DataMessage.actionListen:
      case DataMessage.actionUnlisten:
        break;
      default:
        _outstandingRequests.add(request);
    }
    if (_transportIsReady) {
      _transport.add(request);
    }
    return request.response.then/*<MessageBody>*/((r) {
      _outstandingRequests.remove(request);
      if (r.message.body.status == MessageBody.statusOk) {
        return r.message.body;
      } else {
        throw new ServerError(r.message.body.status, r.message.body.data);
      }
    });
  }

  Future<MessageBody> onDisconnectPut(String path, dynamic value) =>
      _request(new Request.onDisconnectPut(path, value));

  Future<MessageBody> onDisconnectMerge(
          String path, Map<String, dynamic> childrenToMerge) =>
      _request(new Request.onDisconnectMerge(path, childrenToMerge));

  Future<MessageBody> onDisconnectCancel(String path) =>
      _request(new Request.onDisconnectCancel(path));
}
