library eventsource;

export "src/event.dart";

import "dart:async";
import "dart:convert";

import "package:http/http.dart" as http;
import "package:http/src/utils.dart" show encodingForCharset;
import "package:http_parser/http_parser.dart" show MediaType;

import "src/event.dart";
import "src/decoder.dart";

enum EventSourceReadyState {
  CONNECTING,
  OPEN,
  CLOSED,
}

class EventSourceSubscriptionException extends Event implements Exception {
  int statusCode;
  String message;

  @override
  String get data => "$statusCode: $message";

  EventSourceSubscriptionException(this.statusCode, this.message)
      : super(event: "error");
}

class EventSourceUnexpectedClose extends Event implements Exception {
  String message;

  @override
  String get data => "$message";

  EventSourceUnexpectedClose(this.message) : super(event: "error");
}

/// An EventSource client that exposes a [Stream] of [Event]s.
class EventSource extends Stream<Event> {
  // interface attributes

  final Uri url;
  final Map<String, String>? headers;

  EventSourceReadyState get readyState => _readyState;

  Stream<Event> get onOpen => this.where((e) => e.event == "open");
  Stream<Event> get onMessage => this.where((e) => e.event == "message");
  Stream<Event> get onError => this.where((e) => e.event == "error");

  // internal attributes

  StreamController<Event> _streamController =
      new StreamController<Event>.broadcast();
  http.StreamedResponse? _response;

  EventSourceReadyState _readyState = EventSourceReadyState.CLOSED;

  http.Client client;
  Duration _retryDelay = const Duration(milliseconds: 3000);
  String? _lastEventId;
  late EventSourceDecoder _decoder;
  String _body;
  String _method;

  /// Create a new EventSource by connecting to the specified url.
  factory EventSource(url,
      {http.Client? client,
      String? lastEventId,
      Map<String, String>? headers,
      String? body,
      String? method}) {
    // parameter initialization
    url = url is Uri ? url : Uri.parse(url);
    client = client ?? new http.Client();
    body = body ?? "";
    method = method ?? "GET";
    EventSource es = new EventSource._internal(
        url, client, lastEventId, headers, body, method);
    es._start();
    return es;
  }

  EventSource._internal(this.url, this.client, this._lastEventId, this.headers,
      this._body, this._method) {
    _decoder = new EventSourceDecoder(retryIndicator: _updateRetryDelay);
  }

  // proxy the listen call to the controller's listen call
  @override
  StreamSubscription<Event> listen(void onData(Event event)?,
          {Function? onError, void onDone()?, bool? cancelOnError}) =>
      _streamController.stream.listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  /// Attempt to start a new connection.
  Future _start() async {
    _readyState = EventSourceReadyState.CONNECTING;
    var request = new http.Request(_method, url);
    request.headers["Cache-Control"] = "no-cache";
    request.headers["Accept"] = "text/event-stream";
    if (_lastEventId?.isNotEmpty == true) {
      request.headers["Last-Event-ID"] = _lastEventId!;
    }
    headers?.forEach((k, v) {
      request.headers[k] = v;
    });
    request.body = _body;

    _response = await client.send(request);
    if (_response!.statusCode != 200) {
      // server returned an error
      var bodyBytes = await _response!.stream.toBytes();
      String body = _encodingForHeaders(_response!.headers).decode(bodyBytes);
      throw new EventSourceSubscriptionException(_response!.statusCode, body);
    }
    _readyState = EventSourceReadyState.OPEN;
    // start streaming the data
    _response!.stream.transform(_decoder).listen(
        (Event event) {
          if (_readyState != EventSourceReadyState.CLOSED) {
            _streamController.add(event);
            _lastEventId = event.id;
          }
        },
        cancelOnError: true,
        onError: (err) {
          if (_readyState != EventSourceReadyState.CLOSED) {
            _streamController.addError(err);
            _retry();
          }
        },
        onDone: () {
          if (_readyState != EventSourceReadyState.CLOSED) {
            _streamController.addError(
                EventSourceUnexpectedClose("Unexpected close received"));
            _retry();
          }
        });
  }

  /// Retries until a new connection is established. Uses exponential backoff.
  Future _retry() async {
    Duration backoff = _retryDelay;
    while (true && _readyState != EventSourceReadyState.CLOSED) {
      try {
        await _start();
        break;
      } catch (error) {
        _streamController.addError(error);
      }
      await new Future.delayed(backoff);
      backoff *= 2;
    }
  }

  void _updateRetryDelay(Duration retry) {
    _retryDelay = retry;
  }

  Future<void> close() async {
    _readyState = EventSourceReadyState.CLOSED;
    _streamController.close();
    if (_response != null) {
      await _response!.close();
    }
  }
}

/// Returns the encoding to use for a response with the given headers. This
/// defaults to [LATIN1] if the headers don't specify a charset or
/// if that charset is unknown.
Encoding _encodingForHeaders(Map<String, String> headers) =>
    encodingForCharset(_contentTypeForHeaders(headers).parameters['charset']);

/// Returns the [MediaType] object for the given headers's content-type.
///
/// Defaults to `application/octet-stream`.
MediaType _contentTypeForHeaders(Map<String, String> headers) {
  var contentType = headers['content-type'];
  if (contentType != null) return new MediaType.parse(contentType);
  return new MediaType("application", "octet-stream");
}
