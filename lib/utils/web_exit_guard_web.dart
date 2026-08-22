import 'dart:js_interop';
import 'package:web/web.dart' as web;

web.EventListener? _listener;

void registerWebExitGuard(bool Function() shouldPreventExit) {
  void onBeforeUnload(web.Event e) {
    if (shouldPreventExit()) {
      final evt = e as web.BeforeUnloadEvent;
      evt.returnValue = '¿Seguro que deseas salir? Hay una sesión activa.';
      evt.preventDefault();
    }
  }

  _listener = onBeforeUnload.toJS;
  web.window.addEventListener('beforeunload', _listener);
}

void unregisterWebExitGuard() {
  if (_listener != null) {
    web.window.removeEventListener('beforeunload', _listener);
    _listener = null;
  }
}