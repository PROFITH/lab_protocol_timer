void registerWebExitGuard(bool Function() shouldPreventExit) {
  // No need to capture 'beforeunload' in windows
}

void unregisterWebExitGuard() {
  // No-op for desktop
}